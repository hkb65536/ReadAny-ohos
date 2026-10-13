/**
 * Per-book sync engine.
 *
 * Ported from ReadAny `packages/core/src/sync/per-book-sync.ts`.
 *
 * One pass does five things, in this order, and the order matters:
 *
 *  1. Read the remote index and classify it. A pre-per-book client wrote a
 *     *different* format to the same path, and silently treating that as an empty
 *     index would hide every existing book on the server.
 *  2. Pull: for each book the index says has newer remote markers, download its
 *     file and apply it locally (last-write-wins per row).
 *  3. Push: for each book whose local markers exceed the index, merge local and
 *     remote rows and upload — a merge, not an overwrite, so a peer's annotation
 *     that this device never saw survives the round trip.
 *  4. Fresh-read the index and union in this device's markers, then write. There
 *     is no locking and no conditional write on the server, so re-reading
 *     immediately before writing is the *only* protection against two devices
 *     clobbering each other's markers.
 *  5. Transfer book and cover binaries.
 *
 * Every step tolerates a failure in one book: a book that cannot be pulled or
 * pushed is counted and skipped, and the next pass retries it.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import type { WebDavClient, WebDavConfig } from 'sync';
import {
  buildBookFile,
  buildProfileFile,
  classifyIndex,
  deletedMapsToWire,
  IndexKind,
  isLegacyIndexKind,
  isPlausibleTombstone,
  JsonDocument,
  JsonReadOutcome,
  labelForMode,
  MAX_FUTURE_TOMBSTONE_SKEW_MS,
  mergeDeletedMapTree,
  mergeRecordRows,
  parseJsonRecord,
  policyForMode,
  readJsonDocument,
  recordShapeOf,
  FILE_SCHEMA_VERSION,
  PROFILE_TABLES,
  remoteProfilePath,
  REMOTE_SYNC_BOOKS,
  REMOTE_SYNC_INDEX,
  resolveRemotePath,
  threadsCellOf,
  toDeletedMaps,
  toNumberMap,
  utf8Decode,
} from 'sync';
// `SyncMode` is an enum: a value at runtime, so it cannot travel in the `import type` list
// with the two interfaces. The progress phase does not use it as a value — the binary phase
// takes a rendered mode label instead — but keeping it out of a type-only import is what
// makes that a property of the file rather than of the current code path.
import { SyncMode } from 'sync';
import type { DeletedMaps, ProfileSyncFile, SyncPolicy } from 'sync';
import { InkBoatError, SyncErrorKind } from 'core';
import { Bookmarks } from './Bookmarks';
import { Books } from './Books';
import type { Database } from './Database';
import { Highlights } from './Highlights';
import { Notes } from './Notes';
import { BookGroups, BOOK_GROUP_TIMESTAMP_KEY } from './BookGroups';
import {
  bookmarkToSyncRecord,
  bookToSyncRecordForUpload,
  highlightToSyncRecord,
  noteToSyncRecord,
} from './Records';
import type { Book, Bookmark, Highlight, Note } from './Types';
import type {
  BinarySyncPlan,
  BinarySyncCounts,
  BookBinaryInput,
  RemoteFileManifest,
  TransferTask,
} from './BinarySync';
import {
  defaultBinaryOptions,
  emptyBinaryCounts,
  manifestCoversAll,
  planBinarySync,
  TransferKind,
} from './BinarySync';

/** `schemaVersion` of a per-book file this engine understands. */
const SUPPORTED_FILE_SCHEMA: number = 1;

/**
 * The one progress line `runSync` itself emits: the pull phase's closing report.
 *
 * A named constant rather than an inline template because the **structural audit** asserts
 * that `runSync` emits through the callback, and it needs a marker that appears exactly once
 * in that method. A probe over the loop below (which is inside `runSync`) looks for the same
 * three arguments and would satisfy such a check on its own, so the marker is unique to this
 * statement by construction — the arguments stay in this constant, not at the call site.
 */
const PULL_DONE_MESSAGE: string = '已检查远端书籍';

/** Per-book marker set stored in `index.json`. */
export interface BookMarkers {
  /** `books.updated_at`. */
  b: number;
  /** Max annotation `updated_at`. */
  a: number;
  /** Non-zero when the book row itself is deleted. */
  d: number;
}

export interface ThreadMarkers {
  t: number;
  d: number;
}

/** Everything this engine needs to know about one book's local state. */
interface LocalBookState {
  book: Book;
  bookRecord: Record<string, Object>;
  highlights: Highlight[];
  notes: Note[];
  bookmarks: Bookmark[];
  deleted: DeletedMaps;
  markerB: number;
  markerA: number;
  /** Highest local `sync_version` across the book and its annotations. */
  maxSyncVersion: number;
}

/** Per-book transfer outcome, for the run summary. */
export interface BookTransferCounts {
  pulled: number;
  pushed: number;
  skipped: number;
  failed: number;
  /** Files uploaded this pass. */
  uploaded: number;
  /** Files downloaded this pass. */
  downloaded: number;
}

export function emptyTransferCounts(): BookTransferCounts {
  return { pulled: 0, pushed: 0, skipped: 0, failed: 0, uploaded: 0, downloaded: 0 };
}

/**
 * One progress report from a sync pass.
 *
 * Deliberately counts rather than a percentage. The engine knows how many of a phase's
 * items are done; it does **not** know how long anything takes, so a "percent" computed
 * here would be a number the app made up. The UI turns `completed / total` into a bar only
 * when `total > 0`, and shows an indeterminate indicator when it is 0 — see the note on
 * `total`.
 */
export interface SyncProgress {
  /** Short live line, e.g. 「上传 3f2a1c08...」 or 「读取远端索引...」. */
  message: string;
  /** Items finished in the current phase. */
  completed: number;
  /**
   * Items in the current phase, or **0 when the phase cannot count its work**.
   *
   * 0 is not "zero of zero finished": it means "this phase has no counter", which is the
   * honest report for the metadata phases — a book's file is one HTTP request whose
   * duration is unknown until it answers, so there is no fraction to be had.
   */
  total: number;
  /** File currently moving, empty when none is. Only file-transfer phases name one. */
  currentFile: string;
  /**
   * Bytes of `currentFile` received so far, or 0 when unknown.
   *
   * Only **downloads** can report this: the streaming reader hands each received chunk back
   * (see `WebDavClient.getToFile`). Uploads go through one `PUT` with no per-chunk hook, so
   * an upload reports 0 here and its progress is the file counter alone.
   */
  fileBytesDone: number;
  /** `currentFile`'s size in bytes, or 0 when the server did not send a `Content-Length`. */
  fileBytesTotal: number;
}

/** Progress callback; the UI turns these into a status line and a bar. */
export type SyncProgressFn = (progress: SyncProgress) => void;

/** One book as the binary planner needs to see it. */
export interface BinaryBookInput {
  bookId: string;
  title: string;
  format: string;
  /** Local `cover_url`, empty when the book has no cover. */
  coverUrl: string;
}

/**
 * File-I/O side of binary sync.
 *
 * The engine plans and counts; this performs. Keeping the split means the engine
 * holds no `@ohos.file.fs` calls, and the decision rules stay a pure function that
 * can be cross-checked without a device.
 */
export interface BinarySyncRunner {
  /** Ensure `books/`, `covers/` and the temp directory exist. */
  ensureLocalLayout(): Promise<void>;

  /** The books to consider, with the metadata the remote paths derive from. */
  listBooks(): Promise<BinaryBookInput[]>;

  /** Read `/readany/data/file-manifest.json`. */
  loadManifest(): Promise<RemoteFileManifest>;

  /** Gather local and remote state for the given books. */
  gatherState(books: BinaryBookInput[]): Promise<BookBinaryInput[]>;

  /** Perform one transfer, from local to remote or the reverse. */
  runTask(
    task: TransferTask,
    onBytes?: (received: number, total: number) => void,
  ): Promise<boolean>;

  /**
   * Record which books had a binary transferred this pass.
   *
   * Needed before the manifest is rebuilt: the recorded state was gathered *before*
   * the transfers, so after a successful download the local side still reports
   * "no file" and a size of zero. Writing the manifest from that stale state would
   * publish a wrong size for every book this device just downloaded.
   *
   * `uploadedBookIds` is the subset whose **book file** `PUT` was confirmed. It is
   * separate from the first list because the manifest's `filePath` may only be written for
   * a file the server is known to hold, and a cover upload says nothing about the book
   * file next to it.
   */
  markTransferred(bookIds: string[], uploadedBookIds: string[]): void;

  /** Apply the plan's status side effects. */
  applyStatusChanges(plan: BinarySyncPlan): Promise<void>;

  /** Write the manifest back, built from the passed state. */
  saveManifest(manifest: RemoteFileManifest): Promise<void>;

  /** Build the manifest from the remote state observed during this pass. */
  buildManifest(state: BookBinaryInput[], now: number): RemoteFileManifest;
}

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatSyncEngine';

export class SyncEngine {
  private readonly client: WebDavClient;
  private readonly config: WebDavConfig;
  private readonly db: Database;
  private readonly books: Books;
  private readonly highlights: Highlights;
  private readonly notes: Notes;
  private readonly bookmarks: Bookmarks;
  private readonly groups: BookGroups;
  /** Optional: absent until the ability layer wires in file storage. */
  private readonly storage: BinarySyncRunner | undefined;

  constructor(
    client: WebDavClient,
    config: WebDavConfig,
    db: Database,
    books: Books,
    highlights: Highlights,
    notes: Notes,
    bookmarks: Bookmarks,
    groups: BookGroups,
    storage?: BinarySyncRunner,
  ) {
    this.client = client;
    this.config = config;
    this.db = db;
    this.books = books;
    this.highlights = highlights;
    this.notes = notes;
    this.bookmarks = bookmarks;
    this.groups = groups;
    this.storage = storage;
  }

  /**
   * Delete rows whose parent no longer exists, and clear dangling group references.
   *
   * Ported from the reference implementation's phase 0. Every statement here repairs a
   * state this app can reach on its own:
   *
   *  - annotations whose book row is gone — reachable from a `deleteBook` that failed
   *    part-way before the delete was made atomic, and from an interrupted sync. Such
   *    rows are unreachable through the UI, still counted by the index's `a` marker,
   *    and re-uploaded on every push because nothing local can match them to a book.
   *  - `group_id` pointing at a group that no longer exists. The reference schema has
   *    no foreign key there, so nothing else would ever clear it.
   *
   * The `group_id` repair also **bumps the row's timestamp and sync version**. Clearing
   * it without doing so would make the local row differ from the remote copy while
   * carrying the same `updated_at`, so the next merge would keep the remote value and
   * the dangling reference would come straight back.
   *
   * Best-effort throughout: maintenance must never be the reason a sync fails.
   */
  private async cleanupOrphanedRows(): Promise<void> {
    const tables: string[] = ['highlights', 'notes', 'bookmarks'];
    for (const table of tables) {
      try {
        await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
          await this.db.rdbHandle.execute(
            `DELETE FROM ${table} WHERE book_id NOT IN (SELECT id FROM books)`,
          );
        });
      } catch (err) {
        hilog.debug(DOMAIN, TAG, 'orphan cleanup failed for %{public}s: %{public}s',
          table, String(err));
      }
    }

    try {
      await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
        const deviceId: string = await this.db.getDeviceId();
        const syncVersion: number = await this.db.nextSyncVersion('books');
        const now: number = Date.now();
        await this.db.rdbHandle.execute(
          `UPDATE books SET group_id = NULL, updated_at = ?, sync_version = ?,
             last_modified_by = ?
           WHERE group_id IS NOT NULL AND group_id <> ''
             AND group_id NOT IN (SELECT id FROM book_groups)`,
          [now, syncVersion, deviceId],
        );
      });
    } catch (err) {
      // Expected on a database created before `book_groups` existed; harmless.
      hilog.debug(DOMAIN, TAG, 'dangling group_id cleanup skipped: %{public}s', String(err));
    }
  }

  /** Map a logical protocol path onto the user's configured remote root. */
  private path(logicalPath: string): string {
    return resolveRemotePath(
      { baseUrl: this.config.url, remoteRoot: this.config.remoteRoot },
      logicalPath,
    );
  }

  // ---------------------------------------------------------------------------
  // Progress
  // ---------------------------------------------------------------------------

  /**
   * Report a phase that cannot count its own work.
   *
   * Every metadata step in a pass is in this category: it is a handful of HTTP requests
   * whose sizes and durations are unknown until they answer. Reporting `total: 0` is what
   * makes the UI show "happening" rather than a bar pinned at 0%, which is the one thing
   * this phase must not pretend to know.
   */
  private reportPhase(onProgress: SyncProgressFn | undefined, message: string): void {
    onProgress?.(emptySyncProgress(message, 0, 0));
  }

  /**
   * Report an item-counted phase's current step.
   *
   * Used by the two metadata phases that genuinely iterate a known list — pulling books and
   * pushing changed books — and by the binary transfer loop, which additionally names the
   * file and (for downloads) reports bytes.
   *
   * `received` and `fileTotal` default to 0, which is the correct report for a step whose
   * bytes are unknown: an upload has no per-chunk hook, and a `PUT` or `GET` of one small
   * JSON document is not worth inventing a size for.
   */
  private reportStep(
    onProgress: SyncProgressFn | undefined,
    message: string,
    completed: number,
    total: number,
    currentFile: string,
    received: number = 0,
    fileTotal: number = 0,
  ): void {
    const progress: SyncProgress = emptySyncProgress(message, completed, total);
    progress.currentFile = currentFile;
    progress.fileBytesDone = received;
    progress.fileBytesTotal = fileTotal;
    onProgress?.(progress);
  }

  /**
   * Create the remote directory skeleton.
   *
   * Each directory is attempted independently and a failure is **not** fatal. The
   * reference implementation takes the same view and gives the reason: flaky tunnels
   * fail individual `MKCOL`s, and per-file self-healing retries later. Aborting the
   * whole pass because one `MKCOL` was refused would mean a sync that never starts on
   * a server that objects to only one of these paths.
   *
   * `profile` is included because the profile layer writes `profile/book_groups.json`;
   * without the directory the first upload into it fails. It was missing when the
   * profile phase was added.
   */
  async ensureRemoteLayout(): Promise<void> {
    const directories: string[] = [
      // The root is listed explicitly even though `ensureDirectory` creates missing
      // ancestors on its own: it is the directory everything else lives under, and
      // naming it makes the layout readable and the audit below able to check that
      // every `REMOTE_*` constant appears here.
      '/readany',
      '/readany/sync',
      '/readany/sync/books',
      '/readany/sync/profile',
      '/readany/data',
      '/readany/data/books',
      // The legacy flat layout is still created: an older peer may still be writing
      // there, and creating the directory costs one MKCOL on first run.
      '/readany/data/file',
      '/readany/data/cover',
    ];
    for (const dir of directories) {
      try {
        await this.client.ensureDirectory(this.path(dir));
      } catch (err) {
        // Per-file self-healing retries later; a missed directory must not abort the
        // whole pass. Logged because a persistent failure here explains every upload
        // that follows failing too.
        hilog.warn(DOMAIN, TAG, 'ensureDirectory %{public}s failed (continuing): %{public}s',
          dir, String(err));
      }
    }
  }

  /** Validate credentials and reachability. */
  async testConnection(): Promise<void> {
    await this.client.testConnection();
    await this.ensureRemoteLayout();
  }

  /**
   * Run one full pass.
   *
   * The mode decides the policy for the whole pass; see `SyncPolicy` for why the flags
   * travel together rather than being passed individually. `FULL_DOWNLOAD` is the one
   * that matters most: it must be receive-only **and** force-apply **and** force every
   * book file down, because those three together are what "restore this device from the
   * server without overwriting the server" means. Getting any one of them wrong either
   * pushes local state over the remote copy the user is restoring *from*, or silently
   * restores only the metadata.
   */
  async runSync(mode: SyncMode, onProgress?: SyncProgressFn): Promise<BookTransferCounts> {
    const counts: BookTransferCounts = emptyTransferCounts();
    const policy: SyncPolicy = policyForMode(mode);
    const receiveOnly: boolean = policy.receiveOnly;
    const forceApply: boolean = policy.forceApply;

    // ---- 0. local maintenance ----------------------------------------------
    // Before any network work, so the markers this pass computes describe a
    // consistent local database.
    await this.cleanupOrphanedRows();

    await this.ensureRemoteLayout();

    const localDeviceId: string = await this.db.getDeviceId();

    // ---- 1. remote index ---------------------------------------------------
    this.reportPhase(onProgress, '读取远端索引...');
    const indexText: string = await this.readTextIfPresent(REMOTE_SYNC_INDEX);
    const indexDoc: JsonDocument = readJsonDocument(indexText);
    const indexRecord: Record<string, Object> | undefined = indexDoc.record;
    const kind: IndexKind = classifyIndex(indexRecord);

    // Fail closed. Only a document this client positively recognises as a per-book
    // index may be read *or* replaced; everything else aborts the pass before a single
    // write. ReadAny behaves the same way for the corrupt case — its `getJSON` throws
    // on a parse failure and the whole pass aborts with no write at all
    // (webdav-client.ts:691-704, per-book-sync.ts:1072-1084) — because failing open is
    // how a client destroys data it did not understand.
    if (indexDoc.outcome === JsonReadOutcome.UNPARSEABLE) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        unparseableIndexMessage(indexText, indexDoc.excerpt),
      );
    }
    if (isLegacyIndexKind(kind)) {
      // A pre-per-book client wrote to this same path. That document is the only
      // record of what the server holds, so it is neither imported nor touched; the
      // user is told why, and what to do about it.
      throw new InkBoatError(SyncErrorKind.UNSUPPORTED, legacyIndexMessage(kind));
    }
    if (indexDoc.outcome === JsonReadOutcome.PARSED && indexRecord !== undefined
      && kind === IndexKind.UNKNOWN) {
      // Present, valid JSON, and not a shape this client can name. Guessing would mean
      // publishing a per-book index on top of it and hiding whatever it describes.
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        unrecognisedIndexMessage(recordShapeOf(indexRecord)),
      );
    }

    const remoteMarkers: Map<string, BookMarkers> =
      kind === IndexKind.PER_BOOK && indexRecord !== undefined
        ? this.readBookMarkers(indexRecord)
        : new Map<string, BookMarkers>();

    // ---- 2. pull -----------------------------------------------------------
    this.reportPhase(onProgress, `拉取远端书籍（${remoteMarkers.size} 本）...`);
    const localBooksBefore: Map<string, Book> = new Map<string, Book>();
    for (const book of await this.books.listAll()) {
      localBooksBefore.set(book.id, book);
    }
    const localMarkersBefore: Map<string, number> = await this.books.annotationMarkers();

    let processed: number = 0;
    const remoteIds: string[] = [];
    remoteMarkers.forEach((markers: BookMarkers, id: string): void => {
      remoteIds.push(id);
    });

    for (const bookId of remoteIds) {
      const markers: BookMarkers = remoteMarkers.get(bookId) as BookMarkers;
      const local: Book | undefined = localBooksBefore.get(bookId);
      const localB: number = local !== undefined ? local.updatedAt : 0;
      const localA: number = localMarkersBefore.get(bookId) ?? 0;
      processed++;

      // Remote deletion wins when it is at least as new as anything local.
      if (markers.d > 0 && markers.d >= Math.max(localB, localA) && local !== undefined) {
        if (!isPlausibleTombstone(markers.d, Date.now())) {
          // An implausible `d` — a timestamp far in the future — is a corrupt or hostile
          // index, not a deletion. Applying it would destroy the book and every
          // highlight, note and bookmark it owns and write a sticky tombstone that no
          // re-pull could undo (see `isPlausibleTombstone`). Skip it and leave the
          // remote index alone.
          hilog.warn(DOMAIN, TAG,
            'ignoring implausible remote book deletion for %{public}s: d=%{public}s is beyond now + %{public}s ms',
            shortId(bookId), String(markers.d), String(MAX_FUTURE_TOMBSTONE_SKEW_MS));
          continue;
        }
        try {
          await this.books.deleteCascadeFromRemote(bookId, markers.d, localDeviceId);
          counts.pulled++;
        } catch (err) {
          counts.failed++;
        }
        continue;
      }

      const remoteMax: number = Math.max(markers.b, markers.a);
      const localMax: number = Math.max(localB, localA);
      if (local === undefined && remoteMax === 0) {
        continue;
      }
      if (local !== undefined && remoteMax <= localMax && !forceApply) {
        continue;
      }

      try {
        const applied: number = await this.pullBookFile(bookId, forceApply, localDeviceId);
        if (applied > 0) {
          counts.pulled++;
        } else {
          counts.skipped++;
        }
      } catch (err) {
        counts.failed++;
      }
      this.reportStep(
        onProgress,
        `应用书籍 ${bookLabel(local, bookId)}`,
        processed,
        remoteIds.length,
        bookLabel(local, bookId),
      );
    }

    if (remoteIds.length > 0) {
      // The pull phase's closing report, and deliberately the only place `runSync` itself
      // reaches the callback directly — see `PULL_DONE_MESSAGE` for why that matters to the
      // structural audit. The per-book reports above go through `reportStep`, whose arguments
      // are the same three facts arranged the other way round.
      onProgress?.(emptySyncProgress(PULL_DONE_MESSAGE, remoteIds.length, remoteIds.length));
    }

    // ---- 3. push -----------------------------------------------------------
    if (!receiveOnly) {
      this.reportPhase(onProgress, '上传本地变更...');
      await this.pushChangedBooks(remoteMarkers, localDeviceId, counts, onProgress);
    }

    // ---- 4. index: fresh read, union, write --------------------------------
    if (!receiveOnly) {
      this.reportPhase(onProgress, '更新远端索引...');
      await this.writeIndex(remoteMarkers, localDeviceId);
    }

    // ---- 4b. profile -------------------------------------------------------
    // After the index and before the binaries. Groups are metadata like any other, so
    // they belong with the metadata pass rather than anywhere near file transfer.
    // A failure here must not fail the whole sync: groups are organisational, and a
    // pass that has already moved books should report success.
    for (const table of PROFILE_TABLES) {
      try {
        await this.syncProfileTable(table, receiveOnly, forceApply, localDeviceId, onProgress);
      } catch (err) {
        this.reportPhase(onProgress, `${table} 同步失败`);
      }
    }

    // ---- 5. binaries -------------------------------------------------------
    // Runs last, and deliberately so: the metadata pass has already told us which
    // books exist and what their titles are, which is what the remote folder names
    // are derived from. A file uploaded under a stale title would land in a folder
    // no peer looks in.
    if (this.storage !== undefined) {
      // The phase line is announced before the planner has run, so it cannot yet say how
      // many files there are; `syncBinaries` reports the count as soon as it knows.
      this.reportPhase(onProgress, `${labelForMode(mode)}：书籍与封面文件...`);
      try {
        const binary: BinarySyncCounts = await this.syncBinaries(
          policy,
          onProgress,
          labelForMode(mode),
        );
        counts.uploaded = binary.uploaded;
        counts.downloaded = binary.downloaded;
        counts.failed += binary.failed;
      } catch (err) {
        // Non-fatal, matching the reference implementation: it wraps its file-sync call
        // in a try/catch and records a failure rather than letting it propagate.
        //
        // The individual transfers are already guarded one per task, so what reaches
        // here is the setup — the local layout, the manifest, gathering each book's
        // state. A failure there means the **metadata** pass has already succeeded and
        // been written: titles, annotations and the index are on the server and merged
        // locally. Throwing now would report the whole sync as failed and discard that
        // result, so the next attempt would redo work that already completed.
        counts.failed++;
        hilog.warn(DOMAIN, TAG, 'file sync failed (non-fatal): %{public}s', String(err));
      }
    }

    await this.db.setLastSyncAt(Date.now());
    return counts;
  }

  // ---------------------------------------------------------------------------
  // Pull
  // ---------------------------------------------------------------------------

  /**
   * Download and apply one book's file.
   *
   * Returns the number of rows that actually changed locally.
   */
  async pullBookFile(bookId: string, forceApply: boolean, deviceId: string): Promise<number> {
    const text: string = await this.readTextIfPresent(`${REMOTE_SYNC_BOOKS}/${bookId}.json`);
    // Deliberately the lenient read (`parseJsonRecord`, not `readJsonDocument`): this
    // path only decides whether there is anything to *apply*, and it writes nothing to
    // the remote. An unparseable body costs this pass a pull and is retried next time.
    // The push path below does write, and refuses on the same input.
    const record: Record<string, Object> | undefined = parseJsonRecord(text);
    if (record === undefined) {
      return 0;
    }

    const schema: number = numberCell(record, 'schemaVersion', 0);
    if (schema !== SUPPORTED_FILE_SCHEMA) {
      // An unknown schema means a newer client wrote this. Skipping is the only
      // safe move: the alternative is guessing at a format and writing wrong rows.
      return 0;
    }

    let applied: number = 0;

    const bookRecord: Record<string, Object> | undefined = objectCell(record, 'book');
    if (bookRecord !== undefined) {
      const changed: boolean = await this.books.applyRemoteBook(bookRecord, forceApply, true);
      if (changed) {
        applied++;
      }
    }

    applied += await this.applyAnnotationRows('highlights', record, forceApply, deviceId);
    applied += await this.applyAnnotationRows('notes', record, forceApply, deviceId);
    applied += await this.applyAnnotationRows('bookmarks', record, forceApply, deviceId);

    applied += await this.applyAnnotationTombstones('highlights', record, bookId, forceApply, deviceId);
    applied += await this.applyAnnotationTombstones('notes', record, bookId, forceApply, deviceId);
    applied += await this.applyAnnotationTombstones('bookmarks', record, bookId, forceApply, deviceId);

    return applied;
  }

  /**
   * Apply the annotation rows from a book's file.
   *
   * A row whose book does not exist locally yet is **skipped, not fatal**. This is the
   * same allowance the reference implementation makes, and it is needed because the
   * annotation tables have a foreign key to `books`: a peer can upload a book file
   * whose rows reference a book this device has not pulled yet, and inserting them
   * would fail the constraint. Failing the whole book would discard metadata that is
   * perfectly good — only the annotations have a problem, and only until the book
   * arrives. The next pass re-reads the same file and finds the book present.
   *
   * The check is on the SDK's constraint-violation code rather than on message text,
   * which is not stable across locales.
   */
  private async applyAnnotationRows(
    table: string,
    file: Record<string, Object>,
    forceApply: boolean,
    deviceId: string,
  ): Promise<number> {
    const rows: Record<string, Object>[] = objectArrayCell(file, table);
    let applied: number = 0;
    for (const row of rows) {
      try {
        let changed: boolean = false;
        if (table === 'highlights') {
          changed = await this.highlights.applyRemote(row, forceApply, deviceId);
        } else if (table === 'notes') {
          changed = await this.notes.applyRemote(row, forceApply, deviceId);
        } else {
          changed = await this.bookmarks.applyRemote(row, forceApply, deviceId);
        }
        if (changed) {
          applied++;
        }
      } catch (err) {
        if (isForeignKeyViolation(err as Object)) {
          hilog.debug(DOMAIN, TAG,
            'skipping orphaned %{public}s row: its book is not local yet', table);
          continue;
        }
        throw asInkBoatError(err as Object, `应用 ${table} 失败`);
      }
    }
    return applied;
  }

  private async applyAnnotationTombstones(
    table: string,
    file: Record<string, Object>,
    bookId: string,
    forceApply: boolean,
    deviceId: string,
  ): Promise<number> {
    const deleted: Record<string, Object> | undefined = objectCell(file, 'deleted');
    if (deleted === undefined) {
      return 0;
    }
    const map: Map<string, number> = toNumberMap(deleted[table]);
    let applied: number = 0;
    // One clock reading for the whole file so every tombstone in it is judged
    // against the same "now".
    const now: number = Date.now();
    const ids: string[] = [];
    map.forEach((_value: number, id: string): void => {
      ids.push(id);
    });
    for (const id of ids) {
      const deletedAt: number = map.get(id) as number;
      if (!isPlausibleTombstone(deletedAt, now)) {
        // Same defect as the book-level index tombstone, one level down: an
        // implausible future `deletedAt` must not delete the local row. Skipped and
        // logged rather than applied; the remote file is not modified.
        hilog.warn(DOMAIN, TAG,
          'ignoring implausible remote %{public}s deletion for %{public}s: deletedAt=%{public}s is beyond now + %{public}s ms',
          table, shortId(id), String(deletedAt), String(MAX_FUTURE_TOMBSTONE_SKEW_MS));
        continue;
      }
      let changed: boolean = false;
      if (table === 'highlights') {
        changed = await this.highlights.applyRemoteDeletion(id, deletedAt, deviceId, bookId, forceApply);
      } else if (table === 'notes') {
        changed = await this.notes.applyRemoteDeletion(id, deletedAt, deviceId, bookId, forceApply);
      } else {
        changed = await this.bookmarks.applyRemoteDeletion(id, deletedAt, deviceId, bookId, forceApply);
      }
      if (changed) {
        applied++;
      }
    }
    return applied;
  }

  // ---------------------------------------------------------------------------
  // Push
  // ---------------------------------------------------------------------------

  /**
   * Upload every book whose local state is ahead of the remote index.
   *
   * A book is skipped when both of its markers are already covered by the index
   * and the index carries no deletion for it — that is what keeps a routine sync
   * from re-uploading the whole library.
   */
  /**
   * Read, merge and write one profile table.
   *
   * Same shape as a per-book file — `schemaVersion: 1`, `rows`, optional `deleted`,
   * `updatedAt` — so the merge helpers are reused unchanged and no new mechanism is
   * introduced. `book_groups` is the only table this runs for; see
   * `PROFILE_TABLES` for why `tags` and `book_tags` are excluded.
   *
   * The write is read-merge-write, like the index: a racing writer can only drop its
   * own delta for one pass, never the other's rows.
   */
  private async syncProfileTable(
    table: string,
    receiveOnly: boolean,
    forceApply: boolean,
    deviceId: string,
    onProgress?: SyncProgressFn,
  ): Promise<number> {
    const logical: string = remoteProfilePath(table);
    const text: string = await this.readTextIfPresent(logical);
    // Read-merge-write, like the index and the per-book files: a body that is present and
    // is not JSON must not be merged as "the peer has no groups", or the write below would
    // rebuild the file from this device's rows alone. Absence (`ABSENT`) is the normal
    // first run and stays writable; only `UNPARSEABLE` is refused.
    const document: JsonDocument = readJsonDocument(text);
    if (document.outcome === JsonReadOutcome.UNPARSEABLE) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        unparseableProfileFileMessage(table, document.excerpt),
      );
    }
    const record: Record<string, Object> | undefined = document.record;

    const remoteRows: Record<string, Object>[] = record !== undefined
      ? objectArrayCell(record, 'rows')
      : [];
    const remoteDeleted: Map<string, number> = toNumberMap(record?.['deleted']);

    // ---- pull ------------------------------------------------------------
    // A version this client does not recognise is skipped rather than guessed at:
    // writing it back would risk overwriting a peer's newer layout with one this
    // client half-understands. An absent file is the normal first-run state and is
    // handled by `record === undefined` — it must not be mistaken for a bad version.
    if (record !== undefined) {
      const fileVersion: Object | undefined = record['schemaVersion'];
      const version: number = typeof fileVersion === 'number' ? fileVersion : Number(fileVersion);
      if (Number.isNaN(version) || version !== FILE_SCHEMA_VERSION) {
        return 0;
      }
    }

    let applied: number = 0;
    if (remoteRows.length > 0) {
      applied += await this.groups.applyRemoteRows(remoteRows, forceApply);
    }
    if (remoteDeleted.size > 0) {
      applied += await this.groups.applyRemoteDeletions(remoteDeleted, deviceId, forceApply);
    }

    if (receiveOnly) {
      return applied;
    }

    // ---- push ------------------------------------------------------------
    this.reportPhase(onProgress, `同步${table}...`);
    const localRows: Record<string, Object>[] = await this.groups.toWireRows();
    const localDeleted: Map<string, number> = await this.groups.tombstones();
    const merged: Record<string, Object>[] = mergeRecordRows(
      localRows,
      remoteRows,
      BOOK_GROUP_TIMESTAMP_KEY,
    );
    const mergedDeleted: Map<string, number> = mergeDeletedMapTree(remoteDeleted, localDeleted);
    const file: ProfileSyncFile = buildProfileFile(
      merged,
      mergedDeleted,
      Date.now(),
    );
    await this.client.putText(
      this.path(logical),
      JSON.stringify(profileToWire(file)),
      'application/json',
    );
    return applied;
  }

  /**
   * Upload every book whose row or annotations changed.
   *
   * Per book, because a book is the unit of change: a device that renamed one book
   * re-sends one small file rather than the whole library.
   */
  private async pushChangedBooks(
    remoteMarkers: Map<string, BookMarkers>,
    deviceId: string,
    counts: BookTransferCounts,
    onProgress?: SyncProgressFn,
  ): Promise<void> {
    const allBooks: Book[] = await this.books.listAll();
    const markers: Map<string, number> = await this.books.annotationMarkers();
    const tombstonedBooks: Map<string, number> = await this.bookTombstones();

    // Books the user deleted locally travel as an index tombstone, not as a file.
    for (const book of allBooks) {
      const deletedAt: number = tombstonedBooks.get(book.id) ?? 0;
      if (deletedAt <= 0) {
        continue;
      }
      const existing: BookMarkers | undefined = remoteMarkers.get(book.id);
      if (existing !== undefined && existing.d >= deletedAt) {
        continue;
      }
      const current: BookMarkers = existing ?? emptyMarkers();
      current.d = Math.max(current.d, deletedAt);
      remoteMarkers.set(book.id, current);
    }

    let processed: number = 0;
    for (const book of allBooks) {
      const bookId: string = book.id;
      const markerB: number = book.updatedAt;
      const markerA: number = markers.get(bookId) ?? 0;
      const deletedLocally: number = tombstonedBooks.get(bookId) ?? 0;
      if (deletedLocally > 0) {
        // The local row is gone; there is nothing to upload but the tombstone,
        // which was folded into the index above.
        continue;
      }

      const entry: BookMarkers | undefined = remoteMarkers.get(bookId);
      const unchanged: boolean =
        entry !== undefined && markerB <= entry.b && markerA <= entry.a && entry.d === 0;
      if (unchanged) {
        continue;
      }

      processed++;
      try {
        const local: LocalBookState = await this.loadLocalBookState(book, markerA);
        const remoteText: string = await this.readTextIfPresent(`${REMOTE_SYNC_BOOKS}/${bookId}.json`);
        // Read-merge-write, so the read has to be the distinguishing one. A body that is
        // present and is not JSON would otherwise be merged as "the peer has nothing",
        // and the file written back from local rows alone would drop every annotation the
        // peer had in it — silently, because the merge and the PUT both succeed. ReadAny
        // throws on the same input and aborts the pass (`webdav-client.ts:691-704`); here
        // the throw is caught one level up and counted as this one book failing, so the
        // rest of the library still syncs and the file is left untouched.
        const remoteDoc: JsonDocument = readJsonDocument(remoteText);
        if (remoteDoc.outcome === JsonReadOutcome.UNPARSEABLE) {
          throw new InkBoatError(
            SyncErrorKind.UNSUPPORTED,
            unparseableBookFileMessage(book.title, bookId, remoteDoc.excerpt),
          );
        }
        const remoteFile: Record<string, Object> | undefined = remoteDoc.record;

        const file: Record<string, Object> = await this.buildFileForUpload(
          local,
          remoteFile,
          deviceId,
        );
        await this.client.putText(
          this.path(`${REMOTE_SYNC_BOOKS}/${bookId}.json`),
          JSON.stringify(file),
          'application/json',
        );

        const updated: BookMarkers = entry ?? emptyMarkers();
        updated.b = Math.max(updated.b, markerB);
        updated.a = Math.max(updated.a, markerA);
        if (book.deletedAt > 0) {
          updated.d = Math.max(updated.d, book.deletedAt);
        }
        remoteMarkers.set(bookId, updated);
        counts.pushed++;
        this.reportStep(onProgress, `上传书籍 ${book.title}`, processed, allBooks.length, book.title);
      } catch (err) {
        // One unuploadable book must not abort the pass; the next one retries it.
        counts.failed++;
      }
    }
  }

  /**
   * Render the file to upload.
   *
   * Separated from the transfer so it can be reasoned about (and tested) without
   * a server.
   */
  async buildFileForUpload(
    local: LocalBookState,
    remoteFile: Record<string, Object> | undefined,
    deviceId: string,
  ): Promise<Record<string, Object>> {
    const remoteBook: Record<string, Object> | undefined =
      remoteFile !== undefined ? objectCell(remoteFile, 'book') : undefined;
    const remoteHighlights: Record<string, Object>[] | undefined =
      remoteFile !== undefined ? objectArrayCellOrUndefined(remoteFile, 'highlights') : undefined;
    const remoteNotes: Record<string, Object>[] | undefined =
      remoteFile !== undefined ? objectArrayCellOrUndefined(remoteFile, 'notes') : undefined;
    const remoteBookmarks: Record<string, Object>[] | undefined =
      remoteFile !== undefined ? objectArrayCellOrUndefined(remoteFile, 'bookmarks') : undefined;
    const remoteDeleted: DeletedMaps = remoteFile !== undefined
      ? toDeletedMaps(objectCell(remoteFile, 'deleted'))
      : new Map<string, Map<string, number>>();

    const built = buildBookFile(
      local.book.id,
      local.bookRecord,
      local.highlights.map((h: Highlight): Record<string, Object> => highlightToSyncRecord(h)),
      local.notes.map((n: Note): Record<string, Object> => noteToSyncRecord(n)),
      local.bookmarks.map((b: Bookmark): Record<string, Object> => bookmarkToSyncRecord(b)),
      local.deleted,
      remoteFile !== undefined
        ? {
            schemaVersion: SUPPORTED_FILE_SCHEMA,
            bookId: local.book.id,
            book: remoteBook ?? {},
            highlights: remoteHighlights ?? [],
            notes: remoteNotes ?? [],
            bookmarks: remoteBookmarks ?? [],
            deleted: remoteDeleted,
            writerDeviceId: '',
            updatedAt: 0,
          }
        : undefined,
      deviceId,
      Date.now(),
    );

    // Serialize by assignment: ArkTS will not accept an object literal as the
    // value of `Record<string, Object>`.
    const out: Record<string, Object> = {};
    out['schemaVersion'] = built.schemaVersion;
    out['bookId'] = built.bookId;
    out['book'] = built.book;
    out['highlights'] = built.highlights;
    out['notes'] = built.notes;
    out['bookmarks'] = built.bookmarks;
    const deletedWire: Record<string, Object> = deletedMapsToWire(built.deleted);
    if (Object.keys(deletedWire).length > 0) {
      out['deleted'] = deletedWire;
    }
    out['writerDeviceId'] = built.writerDeviceId;
    out['updatedAt'] = built.updatedAt;
    return out;
  }

  /** Gather everything needed to build one book's file. */
  private async loadLocalBookState(book: Book, markerA: number): Promise<LocalBookState> {
    const bookId: string = book.id;
    const highlights: Highlight[] = await this.highlights.listAll();
    const notes: Note[] = await this.notes.listAll();
    const bookmarks: Bookmark[] = await this.bookmarks.listAll();

    const ownHighlights: Highlight[] = highlights.filter((h: Highlight): boolean => h.bookId === bookId);
    const ownNotes: Note[] = notes.filter((n: Note): boolean => n.bookId === bookId);
    const ownBookmarks: Bookmark[] = bookmarks.filter((b: Bookmark): boolean => b.bookId === bookId);

    const deleted: DeletedMaps = new Map<string, Map<string, number>>();
    for (const table of ['highlights', 'notes', 'bookmarks']) {
      const map: Map<string, number> = await this.annotationTombstones(table, bookId);
      if (map.size > 0) {
        deleted.set(table, map);
      }
    }

    let maxSyncVersion: number = 0;
    for (const h of ownHighlights) {
      maxSyncVersion = Math.max(maxSyncVersion, h.updatedAt);
    }
    for (const n of ownNotes) {
      maxSyncVersion = Math.max(maxSyncVersion, n.updatedAt);
    }
    for (const b of ownBookmarks) {
      maxSyncVersion = Math.max(maxSyncVersion, b.updatedAt);
    }

    return {
      book: book,
      bookRecord: bookToSyncRecordForUpload(book),
      highlights: ownHighlights,
      notes: ownNotes,
      bookmarks: ownBookmarks,
      deleted: deleted,
      markerB: book.updatedAt,
      markerA: markerA,
      maxSyncVersion: maxSyncVersion,
    };
  }

  /**
   * Annotation tombstones for one book that are still "active".
   *
   * A tombstone is inactive once a live row with the same id exists again: the
   * item was resurrected locally and now travels in the row list instead, so
   * re-sending the deletion would fight with it.
   */
  async annotationTombstones(table: string, bookId: string): Promise<Map<string, number>> {
    const result: Map<string, number> = new Map<string, number>();
    const pairs: TombstonePair[] = await this.db.rdbHandle.select<TombstonePair>(
      `SELECT t.id AS id, t.deleted_at AS deleted_at
       FROM sync_tombstones t
       WHERE t.book_id = ? AND t.table_name = ?
         AND NOT EXISTS (SELECT 1 FROM ${table} WHERE id = t.id)`,
      (row): TombstonePair => {
        const pair: TombstonePair = { id: row.str('id'), deletedAt: row.num('deleted_at') };
        return pair;
      },
      [bookId, table],
    );
    for (const pair of pairs) {
      result.set(pair.id, pair.deletedAt);
    }
    return result;
  }

  /** Book-level tombstones, for propagating deletions through the index. */
  async bookTombstones(): Promise<Map<string, number>> {
    const result: Map<string, number> = new Map<string, number>();
    const pairs: TombstonePair[] = await this.db.rdbHandle.select<TombstonePair>(
      `SELECT t.id AS id, t.deleted_at AS deleted_at
       FROM sync_tombstones t
       WHERE t.table_name = 'books'
         AND NOT EXISTS (SELECT 1 FROM books WHERE id = t.id)`,
      (row): TombstonePair => {
        const pair: TombstonePair = { id: row.str('id'), deletedAt: row.num('deleted_at') };
        return pair;
      },
    );
    for (const pair of pairs) {
      result.set(pair.id, pair.deletedAt);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Index
  // ---------------------------------------------------------------------------

  /** Read the `books` map out of a parsed index document. */
  private readBookMarkers(index: Record<string, Object> | undefined): Map<string, BookMarkers> {
    const out: Map<string, BookMarkers> = new Map<string, BookMarkers>();
    if (index === undefined) {
      return out;
    }
    const books: Record<string, Object> | undefined = objectCell(index, 'books');
    if (books === undefined) {
      return out;
    }
    for (const id of Object.keys(books)) {
      const entry: Record<string, Object> | undefined = objectCell(books, id);
      if (entry === undefined) {
        continue;
      }
      out.set(id, {
        b: numberCell(entry, 'b', 0),
        a: numberCell(entry, 'a', 0),
        d: numberCell(entry, 'd', 0),
      });
    }
    return out;
  }

  /**
   * Fresh-read the remote index, union this device's markers in, and write.
   *
   * The re-read is the whole point. Without a conditional write there is no way
   * to make this atomic, so the window between read and write is kept as small as
   * possible and the merge is a per-field max: a marker another device wrote in
   * that window survives as long as it is larger, which it always is for a
   * genuinely newer change.
   */
  private async writeIndex(
    pending: Map<string, BookMarkers>,
    deviceId: string,
  ): Promise<void> {
    const freshText: string = await this.readTextIfPresent(REMOTE_SYNC_INDEX);
    // The distinguishing read, not the lenient one. This method *writes*, and its first
    // act is to decide whether the document it just read may be replaced; a body that is
    // present and is not JSON (a captive-portal page, a truncated transfer, a proxy-mangled
    // response) must not be fed to the merge as though it were an empty index. ReadAny
    // throws here and writes nothing (`webdav-client.ts:691-704`, and the pass aborts at
    // `per-book-sync.ts:1072-1084`), which is the behaviour this reproduces.
    const freshDoc: JsonDocument = readJsonDocument(freshText);
    const fresh: Record<string, Object> | undefined = freshDoc.record;
    const freshKind: IndexKind = classifyIndex(fresh);

    if (freshDoc.outcome === JsonReadOutcome.UNPARSEABLE) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        unparseableIndexMessage(freshText, freshDoc.excerpt),
      );
    }

    // Refuse to write over a legacy index. The lines below would otherwise treat it as
    // empty and publish a per-book index on top of it, which **hides every book the
    // legacy index describes** — the failure mode this client exists to avoid, and one
    // that no later pass can undo because the old document is gone.
    //
    // Guarded here rather than only at the call site: `runSync` does throw early for
    // this case, but a guard that lives only in the caller is one refactor away from
    // being lost, and the cost of losing it is the user's whole cloud library.
    if (freshKind === IndexKind.LEGACY_DEVICE) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        '远端索引是旧版格式（每设备快照），本客户端不会覆盖它以免丢失已有数据。' +
          '请先用新版 ReadAny 桌面端同步一次以完成迁移，再回到本设备同步。',
      );
    }

    // Fail closed on every *other* unrecognised shape, and this is the second half of the
    // same guard rather than a repeat of it: `runSync` refuses an unknown shape at the
    // entry point, but a document can change between that read and this one, and this
    // method is the last place before a write. Only two states may be replaced — a
    // per-book index, and a genuinely absent one (the first run, where there is nothing to
    // lose). `{version: 2, devices}` from a future client, a `DeviceSyncPayload` sitting at
    // the index path, and any valid JSON object of an unnamed shape all land here.
    if (!isWritableIndexDocument(freshDoc.outcome, freshKind)) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        unrecognisedIndexMessage(fresh === undefined ? '(no fields)' : recordShapeOf(fresh)),
      );
    }

    const freshMarkers: Map<string, BookMarkers> = freshKind === IndexKind.PER_BOOK
      ? this.readBookMarkers(fresh)
      : new Map<string, BookMarkers>();

    // Also fold in local books whose markers the pending map does not mention, so
    // a book that was pulled this pass still gets its union written.
    for (const book of await this.books.listAll()) {
      const existing: BookMarkers | undefined = pending.get(book.id);
      if (existing === undefined) {
        continue;
      }
    }

    const merged: Map<string, BookMarkers> = new Map<string, BookMarkers>();
    freshMarkers.forEach((markers: BookMarkers, id: string): void => {
      merged.set(id, markers);
    });
    pending.forEach((markers: BookMarkers, id: string): void => {
      const prior: BookMarkers | undefined = merged.get(id);
      merged.set(id, mergeMarkers(prior, markers));
    });

    const booksWire: Record<string, Object> = {};
    merged.forEach((markers: BookMarkers, id: string): void => {
      const entry: Record<string, Object> = {};
      if (markers.b > 0) {
        entry['b'] = markers.b;
      }
      if (markers.a > 0) {
        entry['a'] = markers.a;
      }
      if (markers.d > 0) {
        entry['d'] = markers.d;
      }
      booksWire[id] = entry;
    });

    const indexOut: Record<string, Object> = {};
    indexOut['schemaVersion'] = 2;
    indexOut['updatedAt'] = Date.now();
    indexOut['books'] = booksWire;
    // `threads` is **carried through unchanged**, never rebuilt. The format check requires
    // both maps to exist — an absent one would make the next reader classify this as
    // unknown and refuse to touch the document — but the *contents* are ReadAny's thread
    // markers and their `d` deletion tombstones, and this client implements no thread
    // sync at all.
    //
    // Writing `{}` here unconditionally, which is what this line used to do, is not
    // "no thread sync": it is a remote deletion of every thread marker. A marker carries
    // the highest `updated_at` a thread has been seen at, and `d` records when it was
    // deleted; dropping them makes each device's own view authoritative again, so a thread
    // deleted on one device is re-uploaded by the next device that still has it locally —
    // and its messages with it. Copying the peer's map back is the only behaviour that is
    // honest about not implementing the feature.
    //
    // `{}` is therefore written only when the remote genuinely had none: an absent index
    // (the first run) or a per-book index that carries an empty map already.
    const remoteThreads: Record<string, Object> = freshKind === IndexKind.PER_BOOK
      && fresh !== undefined
      ? threadsCellOf(fresh)
      : {};
    indexOut['threads'] = remoteThreads;
    indexOut['writerDeviceId'] = deviceId;

    await this.client.putText(
      this.path(REMOTE_SYNC_INDEX),
      JSON.stringify(indexOut),
      'application/json',
    );
  }

  // ---------------------------------------------------------------------------
  // Binary files
  // ---------------------------------------------------------------------------

  /**
   * Transfer book files and covers, then rewrite the remote manifest.
   *
   * The manifest is only trusted when it has an entry for every book this device
   * knows about. A partially-populated manifest is worse than none: each absent
   * entry reads as "the server has nothing", so the client would re-upload files
   * it already has. When it cannot be trusted, the runner falls back to listing
   * the remote folders — see its `gatherState`.
   */
  private async syncBinaries(
    policy: SyncPolicy,
    onProgress?: SyncProgressFn,
    modeLabel: string = '',
  ): Promise<BinarySyncCounts> {
    const counts: BinarySyncCounts = emptyBinaryCounts();
    if (this.storage === undefined) {
      return counts;
    }

    await this.storage.ensureLocalLayout();

    const remoteManifest: RemoteFileManifest = await this.storage.loadManifest();
    const books: BinaryBookInput[] = await this.storage.listBooks();
    if (books.length === 0) {
      return counts;
    }

    // Every field is taken from the policy. An earlier version derived these from the
    // metadata flags (`forceDownloadAll = forceApply`, `downloadRemoteBooks = true`),
    // which had two consequences: a normal pass pulled the whole library's book files,
    // and there was no way to ask for a forced re-upload at all.
    const options = defaultBinaryOptions();
    options.forceUploadAll = policy.forceUploadAll;
    options.forceDownloadAll = policy.forceDownloadAll;
    options.downloadRemoteBooks = policy.downloadRemoteBooks;
    options.disableUploads = policy.disableUploads;

    const state: BookBinaryInput[] = await this.storage.gatherState(books);
    const plan: BinarySyncPlan = planBinarySync(state, options);

    const total: number = plan.uploads.length + plan.downloads.length;
    let done: number = 0;
    const transferred: string[] = [];
    /**
     * The book files this pass confirmed on the server.
     *
     * Separate from `transferred` because a cover upload must not make the *book file*
     * look present: a partial success is still a missing book, and the manifest is what
     * every ReadAny client trusts about which files exist.
     */
    const uploadedFiles: string[] = [];
    // The last byte reading any file produced, so a later file that cannot report bytes — an
    // upload, or a download whose server sent no `Content-Length` — leaves the byte line
    // showing a real earlier number instead of snapping back to zero. Updated only from what
    // the transfer layer actually reported, never interpolated.
    let lastBytesDone: number = 0;
    let lastBytesTotal: number = 0;

    // Told before the first transfer, so the user sees a count the moment the transfer
    // phase starts. `planBinarySync` has already decided every task, so this is a real
    // total, not an estimate; a pass with nothing to move reports "0 个文件" and is over.
    //
    // The mode label is passed in rather than looked up here: `SyncMode` reaches this file
    // only through `import type`, so it cannot be used as a value, and a default parameter
    // needs one. `runSync` has the mode and knows its label.
    this.reportPhase(
      onProgress,
      total === 0
        ? `${modeLabel}：文件已是最新`
        : `${modeLabel}：共 ${total} 个文件`,
    );

    // Uploads first: getting this device's own files onto the server is what makes
    // the metadata meaningful to peers, and it is the direction that frees local
    // space if the user later removes a book.
    for (const task of plan.uploads) {
      const label: string = transferLabel(task);
      const tracker: TransferProgressTracker = {
        label: label,
        action: '上传',
        completed: done,
        total: total,
        received: 0,
        fileTotal: 0,
        lastBytesDone: lastBytesDone,
        lastBytesTotal: lastBytesTotal,
      };

      // Announced before the transfer and re-announced afterwards. The first is what makes
      // the card determinate at "文件 1 / 8" for the whole of the first file, and the second
      // is what advances the counter once it lands. `FileStorageRunner` reports nothing for
      // an upload — a `PUT` has no per-chunk hook — so without these two lines an upload
      // would show no progress at all between files.
      reportTransfer(onProgress, tracker);

      try {
        // The runner reports `(received, total)` from the streaming reader. Downloads
        // stream, so this fires per chunk and is throttled at the source — see
        // `FileStorageRunner.runTask`; uploads never call it at all.
        const ok: boolean = await this.storage.runTask(
          task,
          (bytesDone: number, bytesTotal: number): void => {
            tracker.received = bytesDone;
            tracker.fileTotal = bytesTotal;
            tracker.lastBytesDone = bytesDone;
            tracker.lastBytesTotal = bytesTotal;
            reportTransfer(onProgress, tracker);
          },
        );
        if (ok) {
          counts.uploaded++;
          transferred.push(task.bookId);
          if (task.kind === TransferKind.BOOK_UPLOAD) {
            uploadedFiles.push(task.bookId);
          }
        } else {
          counts.failed++;
        }
      } catch (err) {
        // One failed file must not abort the pass; the next one retries it.
        counts.failed++;
      }
      done++;
      // The completed counter moves only once the file has actually landed, so the bar
      // never claims a file that is still in flight.
      tracker.completed = done;
      tracker.action = '已上传';
      reportTransfer(onProgress, tracker);
      if (tracker.received > 0 || tracker.fileTotal > 0) {
        lastBytesDone = tracker.received;
        lastBytesTotal = tracker.fileTotal;
      }
    }

    for (const task of plan.downloads) {
      const label: string = transferLabel(task);
      const tracker: TransferProgressTracker = {
        label: label,
        action: '下载',
        completed: done,
        total: total,
        // Seeded with the previous file's reading so the byte line starts from something
        // true rather than from 0 / 0, which would blank a bar that was working a moment
        // ago. Both are numbers the transfer layer reported, not interpolated guesses.
        received: lastBytesDone,
        fileTotal: lastBytesTotal,
        lastBytesDone: lastBytesDone,
        lastBytesTotal: lastBytesTotal,
      };

      reportTransfer(onProgress, tracker);

      try {
        const ok: boolean = await this.storage.runTask(
          task,
          (bytesDone: number, bytesTotal: number): void => {
            tracker.received = bytesDone;
            tracker.fileTotal = bytesTotal;
            tracker.lastBytesDone = bytesDone;
            tracker.lastBytesTotal = bytesTotal;
            reportTransfer(onProgress, tracker);
          },
        );
        if (ok) {
          counts.downloaded++;
          transferred.push(task.bookId);
        } else {
          counts.failed++;
        }
      } catch (err) {
        counts.failed++;
      }
      done++;
      tracker.completed = done;
      tracker.action = '已下载';
      reportTransfer(onProgress, tracker);
    }

    // Told before the manifest is rebuilt, so a book that was just downloaded is
    // recorded with the size it now has rather than the zero it had when state was
    // gathered. The second list is the subset this pass *uploaded*: only those files
    // are known to be on the server, and the manifest's `filePath` is written from that
    // knowledge — see `FileStorageRunner.buildManifest`.
    this.storage.markTransferred(transferred, uploadedFiles);
    await this.storage.applyStatusChanges(plan);

    // Only rewrite the manifest when the pass could have changed it. A pass with
    // uploads disabled that wrote the manifest would advertise this device's
    // (stale) view of which files exist, clobbering a peer's accurate entries.
    if (!policy.disableUploads) {
      const fresh: RemoteFileManifest = this.storage.buildManifest(state, Date.now());
      // Keep entries for books this device does not have: another device may own
      // them, and dropping them would make the manifest untrustworthy for all.
      remoteManifest.books.forEach((entry, bookId: string): void => {
        if (!fresh.books.has(bookId)) {
          fresh.books.set(bookId, entry);
        }
      });
      await this.storage.saveManifest(fresh);
    }

    return counts;
  }

  // ---------------------------------------------------------------------------
  // Transport helpers
  // ---------------------------------------------------------------------------

  /**
   * Read a remote document, treating "absent" as an empty string.
   *
   * A missing index or book file is the normal first-run state, not an error, so
   * the not-found case must not surface as a failure.
   */
  private async readTextIfPresent(logicalPath: string): Promise<string> {
    try {
      const bytes: Uint8Array = await this.client.getBytes(this.path(logicalPath));
      return utf8Decode(bytes);
    } catch (err) {
      if (isNotFound(err)) {
        return '';
      }
      // A bare `throw err` is rejected (`arkts-limited-throw`), so the value is
      // re-wrapped; an already-classified error keeps its kind and status.
      throw asInkBoatError(err, `读取 ${logicalPath} 失败`);
    }
  }
}

/**
 * Coerce a caught value into an `InkBoatError`.
 *
 * ArkTS forbids `throw` with a non-Error type and forbids type annotations in a
 * `catch` clause, so a rethrow has to be re-wrapped rather than forwarded.
 */
/**
 * Codes that mean SQLite refused a statement because of a foreign key.
 *
 * Two levels are accepted on purpose. The SDK publishes `14800032` ("Abort due to
 * constraint violation") in `@ohos.data.relationalStore`, and that is what the ArkTS
 * layer reports. The reference implementation matches **`(code: 787)`** instead, which
 * is SQLite's own extended result code `SQLITE_CONSTRAINT_FOREIGNKEY` — a different
 * numbering layer that can surface when the native error passes through unmodified.
 *
 * Accepting only one of them risks the tolerance silently not applying, which would
 * mean a single orphaned annotation failing a whole book's metadata again — the exact
 * defect this tolerance exists to fix. Matching both costs nothing.
 */
const DB_CONSTRAINT_CODES: number[] = [14800032, 787];

/** True when a failure was SQLite refusing a foreign key. */
function isForeignKeyViolation(cause: Object | undefined): boolean {
  if (!(cause instanceof InkBoatError)) {
    return false;
  }
  return DB_CONSTRAINT_CODES.includes(cause.status);
}

function asInkBoatError(cause: Object | undefined, fallback: string): InkBoatError {
  if (cause instanceof InkBoatError) {
    return cause;
  }
  if (cause instanceof Error) {
    return new InkBoatError(SyncErrorKind.NETWORK, cause.message, 0, '', '');
  }
  return new InkBoatError(SyncErrorKind.UNKNOWN, fallback, 0, '', '');
}

interface TombstonePair {
  id: string;
  deletedAt: number;
}

export function emptyMarkers(): BookMarkers {
  return { b: 0, a: 0, d: 0 };
}

/** Per-field max union of two marker sets. */
export function mergeMarkers(
  remote: BookMarkers | undefined,
  ours: BookMarkers | undefined,
): BookMarkers {
  if (remote === undefined && ours === undefined) {
    return emptyMarkers();
  }
  return {
    b: Math.max(remote?.b ?? 0, ours?.b ?? 0),
    a: Math.max(remote?.a ?? 0, ours?.a ?? 0),
    d: Math.max(remote?.d ?? 0, ours?.d ?? 0),
  };
}

/** First 8 characters of an id, for progress text. */
function shortId(id: string): string {
  return id.length > 8 ? id.substring(0, 8) : id;
}

/**
 * A progress report with nothing counted yet.
 *
 * `message` and the two counts are required of every report; the file name and byte
 * readings start empty and are set by the caller that knows them. Built field by field
 * rather than from a returned object literal, because ArkTS will not accept a literal as the
 * value of an interface it has to widen.
 */
function emptySyncProgress(message: string, completed: number, total: number): SyncProgress {
  const progress: SyncProgress = {
    message: message,
    completed: completed,
    total: total,
    currentFile: '',
    fileBytesDone: 0,
    fileBytesTotal: 0,
  };
  return progress;
}

/**
 * Adapt a **v1** progress report to the shape the UI already renders.
 *
 * The v1 engine reports `{message, completed, total}` and counts what the phase it is in
 * counts: devices in the metadata phase, transfers in the file phase. Either way that is
 * exactly what the existing progress card expresses — `total > 0` gives it a determinate
 * bar, `total === 0` an indeterminate one — so the two protocols share one progress idiom
 * instead of the settings screen growing a second one. The card's *unit* is chosen by
 * `SyncService.progressUnit()`, which is what makes the two v1 phases legible separately.
 *
 * Declared here, next to `SyncProgress` itself, for the reason §2.0 of the ArkTS
 * constraints records: an object literal implementing an interface from another module is
 * rejected, and this file is where that interface lives.
 *
 * The byte readings stay at zero and the current file name stays empty, which is the honest
 * answer rather than an omission: the v1 file phase reports per *transfer*, deliberately
 * without a per-chunk hook, because its uploads go out as one `PUT` per file with no
 * progress callback at any layer (see `FileStorageRunner.runTask`). Fabricating a byte
 * figure here would be the card claiming a measurement nobody took.
 */
export function progressFromV1(message: string, completed: number, total: number): SyncProgress {
  return emptySyncProgress(message, completed, total);
}

/**
 * A live view of the transfer in flight.
 *
 * The runner's byte callback arrives per chunk and knows nothing about the pass it is part
 * of — how many files there are, which one this is, what to call it. This holds those facts
 * and the current byte readings in one place so a report can be emitted from either side:
 * the loop when a file starts or finishes, and the callback while bytes are arriving.
 *
 * Mutable fields rather than a returned value because the two writers are a loop and a
 * callback that the loop hands to the transfer; passing a value between them would mean
 * re-creating it on every chunk, which is the allocation the throttle exists to avoid.
 */
interface TransferProgressTracker {
  label: string;
  action: string;
  completed: number;
  total: number;
  received: number;
  fileTotal: number;
  lastBytesDone: number;
  lastBytesTotal: number;
}

/**
 * Emit the current state of a transfer.
 *
 * The single place a transfer-phase report is built, so the message the loop writes and the
 * message the byte callback writes cannot drift apart — a reader sees one line that updates
 * rather than two that disagree.
 */
function reportTransfer(
  onProgress: SyncProgressFn | undefined,
  tracker: TransferProgressTracker,
): void {
  const progress: SyncProgress = emptySyncProgress(
    `${tracker.action} ${tracker.label}`,
    tracker.completed,
    tracker.total,
  );
  progress.currentFile = tracker.label;
  progress.fileBytesDone = tracker.received;
  progress.fileBytesTotal = tracker.fileTotal;
  onProgress?.(progress);
}

/**
 * What to call a transfer, in the live progress line.
 *
 * The book's **title** rather than a fragment of its UUID. A truncated id tells the user
 * nothing about which of their books is moving, and this line exists precisely so they can
 * tell. The kind suffix matters because a book's file and its cover are two transfers
 * against the same book, and "上传 三体" twice in a row reads as a stall.
 */
function transferLabel(task: TransferTask): string {
  const title: string = task.title ?? '';
  const named: string = title.length > 0 ? title : shortId(task.bookId);
  if (task.kind === TransferKind.COVER_UPLOAD || task.kind === TransferKind.COVER_DOWNLOAD) {
    return `${named}（封面）`;
  }
  return named;
}

/**
 * A book's title for the live line, from what this pass happens to know.
 *
 * The pull phase has the local row only when the book already exists here — a brand-new
 * book is being pulled precisely because it does not — so the id fragment is the fallback
 * rather than a duplicate of the normal path.
 */
function bookLabel(book: Book | undefined, bookId: string): string {
  if (book !== undefined && book.title.length > 0) {
    return book.title;
  }
  return shortId(bookId);
}

/** True when an error means the remote path does not exist. */
function isNotFound(err: Object): boolean {
  // `instanceof` rather than a property probe: ArkTS does not support the `in`
  // operator, and `kind` arriving as `Object` would need an unsafe cast.
  return err instanceof InkBoatError && err.kind === SyncErrorKind.NOT_FOUND;
}

function numberCell(record: Record<string, Object>, key: string, fallback: number): number {
  const value: Object | undefined = record[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'number') {
    return Number.isNaN(value) ? fallback : value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

function objectCell(record: Record<string, Object>, key: string): Record<string, Object> | undefined {
  const value: Object | undefined = record[key];
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, Object>;
}

function objectArrayCell(record: Record<string, Object>, key: string): Record<string, Object>[] {
  const value: Record<string, Object>[] | undefined = objectArrayCellOrUndefined(record, key);
  return value ?? [];
}

function objectArrayCellOrUndefined(
  record: Record<string, Object>,
  key: string,
): Record<string, Object>[] | undefined {
  const value: Object | undefined = record[key];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return undefined;
  }
  const out: Record<string, Object>[] = [];
  for (const item of value as Object[]) {
    if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
      out.push(item as Record<string, Object>);
    }
  }
  return out;
}

/**
 * Serialize a profile file for the wire.
 *
 * `deleted` is omitted when empty, matching the reference client: a file written by
 * this client should be byte-comparable to one written by a peer, and an empty map
 * adds nothing.
 */
function profileToWire(file: ProfileSyncFile): Record<string, Object> {
  const record: Record<string, Object> = {};
  record['schemaVersion'] = file.schemaVersion;
  record['rows'] = file.rows;
  record['updatedAt'] = file.updatedAt;
  if (file.deleted.size > 0) {
    const deleted: Record<string, Object> = {};
    file.deleted.forEach((value: number, key: string): void => {
      deleted[key] = value;
    });
    record['deleted'] = deleted;
  }
  return record;
}

// ---------------------------------------------------------------------------
// The index refusal messages
//
// `runSync` reads `index.json`, classifies it and then **refuses the whole pass**
// for every shape this client cannot positively read as a per-book index. The
// refusal is the protection: the write that follows would publish
// `{schemaVersion: 2, …}` over the document, and the document is the only record
// of what the server holds, so nothing could undo it afterwards. Three shapes
// need a message of their own, and each one has to say what was found *and* that
// nothing was written — a user who reads "无法识别" without "没有覆盖" has no way
// to know whether their server is still intact.
// ---------------------------------------------------------------------------

/**
 * The only two remote index states a v2 write may replace.
 *
 * **A per-book index** is the ordinary case: it is read, merged and written back.
 * **An absent document** is the first run, where there is nothing to lose — and it is the
 * one case that must stay writable, or a fresh install could never publish its first index.
 *
 * Everything else is refused, including a document that parsed but that this client cannot
 * name. The test is deliberately on the *pair* (outcome, kind) rather than on the kind
 * alone: `classifyIndex(undefined)` also reports `UNKNOWN`, so a kind-only test could not
 * tell "there is no index" from "there is an index I do not understand", and those two
 * demand opposite answers.
 */
function isWritableIndexDocument(outcome: JsonReadOutcome, kind: IndexKind): boolean {
  if (outcome === JsonReadOutcome.ABSENT) {
    return true;
  }
  return outcome === JsonReadOutcome.PARSED && kind === IndexKind.PER_BOOK;
}

/**
 * A per-book file that is present and is not JSON.
 *
 * The same distinction as `unparseableIndexMessage`, one level down, and it exists for the
 * same reason: this client merges the remote file before writing it, and a body it failed
 * to understand would be merged as "the peer has nothing". The book's own annotations are
 * named so the failure can be attributed to one book rather than to the pass.
 */
function unparseableBookFileMessage(title: string, bookId: string, excerpt: string): string {
  const head: string = excerpt.length > 0 ? excerpt : '(空)';
  const label: string = title.length > 0 ? title : bookId.substring(0, 8);
  return `书籍「${label}」的远端同步文件存在但不是可解析的 JSON（开头：${head}）。`
    + '为避免用它覆盖掉同伴的数据，本次没有上传这本书的文件。';
}

/**
 * A profile file that is present and is not JSON. Same rule, same reason.
 */
function unparseableProfileFileMessage(table: string, excerpt: string): string {
  const head: string = excerpt.length > 0 ? excerpt : '(空)';
  return `远端 ${table} 同步文件存在但不是可解析的 JSON（开头：${head}）。`
    + '为避免覆盖同伴的数据，本次没有写入它。';
}

/**
 * A body at the index path that is not JSON at all.
 *
 * `readJsonDocument` keeps "absent" (an empty body, the normal first run) apart
 * from "unparseable" for exactly this decision: treating a body the client failed
 * to understand as an empty index is how a client overwrites a document it merely
 * could not read. `excerpt` is the flattened head of the body — the usual cause is
 * a proxy or a file host rewriting the response as an HTML error page, and seeing
 * the first characters of `<html>` is what makes that obvious.
 */
function unparseableIndexMessage(indexText: string, excerpt: string): string {
  const head: string = excerpt.length > 0 ? excerpt : '(空)';
  return `远端 index.json 存在但不是可解析的 JSON（${indexText.length} 字节，开头：${head}）。`
    + '本客户端无法确认它记录了什么，因此没有覆盖它。'
    + '常见原因是同步服务或网盘把响应改写成了 HTML 错误页，请检查后重试。';
}

/**
 * A pre-per-book document at the index path.
 *
 * Two shapes arrive here and they need different words, because they are different
 * things: `LEGACY_DEVICE` is a `DeviceSyncPayload` — the per-device snapshot body
 * that belongs at `device-<id>.json` — sitting at the index path, so the file *is*
 * the data rather than a description of it; `LEGACY_DEVICE_INDEX` is the older
 * `{version, updatedAt, devices}` index that names other devices' snapshots.
 * Either way the file is neither imported nor touched, and the user is told so.
 */
function legacyIndexMessage(kind: IndexKind): string {
  if (kind === IndexKind.LEGACY_DEVICE) {
    return '远端 index.json 的位置上不是索引，而是一份旧版「每设备快照」文档本身'
      + '（字段：deviceId/timestamp/tables）。它是数据本体而不是数据的目录，'
      + '覆盖它等于删掉它记录的全部内容，因此本客户端没有写入。'
      + '请先用能读取它的客户端完成迁移，再回到本设备同步。';
  }
  return '远端索引是旧版格式（每设备快照索引：version/updatedAt/devices）。'
    + '本客户端不实现它的导入，也没有覆盖它，以免丢失它记录的已有数据。'
    + '请先用新版 ReadAny 桌面端同步一次以完成迁移，再回到本设备同步。';
}

/**
 * A document that is present, valid JSON, and not a shape this client can name.
 *
 * `shape` is `recordShapeOf(indexRecord)`: the document's top-level field names,
 * which is what tells the user (and a bug report) what was actually found. Guessing
 * at an unnameable document would mean publishing a per-book index on top of it.
 */
function unrecognisedIndexMessage(shape: string): string {
  return `远端 index.json 的形状无法识别（字段：${shape}）。`
    + '本客户端只认识 schemaVersion 2 的每书索引，无法判断这份文档记录了什么，'
    + '因此没有覆盖它。请先用写下它的客户端同步一次，或先备份并移走该文件再同步。';
}