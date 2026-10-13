/**
 * The v1 per-device protocol's **file phase**: book files, covers and the remote manifest.
 *
 * Ported from ReadAny **v1.3.6** `packages/core/src/sync/sync-files.ts` (`syncFiles`,
 * `loadRemoteListings`, `loadRemoteFileManifest`, `saveRemoteFileManifest`,
 * `buildUploadFileTask`, `buildDownloadFileTask`, `buildUploadCoverTask`,
 * `buildDownloadCoverTask`, `downloadBookFile`), read at the tag and not at `HEAD`.
 *
 * ## What this module deliberately does not contain
 *
 * v1.3.6's file phase ends with three routines and **every one of them deletes or
 * moves**:
 *
 *  1. `cleanupRemoteOrphans` — `DELETE`s `/readany/data/books/{title}-{uuid}` folders
 *     whose uuid is not in the local `books WHERE deleted_at IS NULL` set, and every
 *     name under `/readany/data/file` and `/readany/data/cover` whose stem is not a
 *     current book id. A client with an empty or partial library would therefore delete
 *     the user's books **from the server**.
 *  2. `cleanupLocalOrphans` — deletes local `books/{id}.{ext}` and `covers/*` whose id
 *     is not in that same set. In v1.3.6 it runs in **every** mode with no opt-out flag.
 *  3. `migrateBookRemoteState` — renames a stale `{title}-{id}` folder by `MOVE`-ing each
 *     child, and moves legacy `/readany/data/file/{id}.{ext}` and
 *     `/readany/data/cover/{id}.{ext}` into the per-book folder.
 *
 * None of the three is implemented here — not guarded, not behind a flag, **absent** —
 * so none of them can be reached or mis-triggered. There is no delete call anywhere in
 * this module and nothing here issues a MOVE. `tools/verify-sync-routing.mjs` asserts
 * both properties against the source text, and `tools/_mutate-sync-routing.mjs` proves
 * the assertions bite.
 *
 * The consequence is deliberate and stated plainly: a residue of stale
 * `{old-title}-{id}` folders and of legacy `/readany/data/file/{id}.{ext}` copies can
 * accumulate on the server. That wastes space. The alternative deletes the user's data,
 * and a file that is merely unreferenced is not a file that is wrong.
 *
 * ## The three rules this module must never break
 *
 * 1. **A book absent from the local library is not a deletion.** Nothing here removes
 *    anything from the server, so there is no place for that inference to be made.
 * 2. **`filePath` is advertised only for a file this pass *knows* is on the server.**
 *    The manifest is what ReadAny trusts, so an entry that claims a file the server does
 *    not have makes the book permanently invisible to every client. "Present" therefore
 *    means one of exactly two things: a scan of the remote folder found the file, or this
 *    pass uploaded it and the `PUT` reported success. A local file that merely exists is
 *    **not** evidence, and a planned upload that failed is not either. (The v2 path had
 *    this defect — `FileStorageRunner.buildManifest` used `remote || local` — and it is
 *    fixed there too, in the same change.)
 * 3. **A manifest that exists and cannot be parsed aborts the manifest write.** It is
 *    never replaced by this device's narrower view. `FileStorageRunner.loadManifest`
 *    already refuses rather than returning an empty manifest, and the refusal is
 *    propagated here instead of swallowed; the transfers still run, because they are
 *    useful and safe, and only the *write* is abandoned.
 *
 * ## Retention rule
 *
 * The manifest written at the end of a pass carries every entry this device can justify
 * (state gathered plus this pass's successes) **plus** every entry the previous manifest
 * held for a book this device does not know. Another device may own that book; dropping
 * its entry would make the manifest untrustworthy for everyone, which is exactly the
 * defect `manifestCoversAll` exists to catch on the read side.
 */

import {
  buildBookFolderName,
  buildBookRemoteCover,
  buildBookRemoteFile,
  isCoverFileName,
  isBookFileName,
  REMOTE_BOOKS_ROOT,
  REMOTE_COVERS,
  REMOTE_DATA,
  REMOTE_FILES,
  REMOTE_FILE_MANIFEST,
  resolveRemotePath,
} from 'sync';
import type { RemoteResource, WebDavConfig, WebDavClient } from 'sync';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InkBoatError, SyncErrorKind } from 'core';

import type { Book } from './Types';
import type {
  BinarySyncOptions,
  BinarySyncPlan,
  BookBinaryInput,
  LocalBinaryState,
  ManifestEntry,
  RemoteBinaryState,
  RemoteFileManifest,
  TransferTask,
  V1FileCounts,
  V1FileProgressFn,
  V1FileRunner,
} from './BinarySync';
import {
  emptyManifest,
  emptyManifestEntry,
  emptyV1FileCounts,
  manifestCoversAll,
  manifestToWire,
  planBinarySync,
  TransferKind,
  unknownRemoteState,
} from './BinarySync';
import { Books } from './Books';
import { FileStorage } from './FileStorage';
import { FileStorageRunner } from './FileStorageRunner';
import { canonicalBookFilePath, canonicalBookCoverPath } from './V1BookPaths';

/**
 * Re-exported so a caller can name the phase's contract without reaching past this module.
 * The declaration itself lives in `./BinarySync`; see the note there for why.
 */
export type { V1FileCounts, V1FileProgressFn, V1FileRunner } from './BinarySync';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatV1Files';

/** Default cover extension, matching the reference's `getExt(cover_url) || "jpg"`. */
const DEFAULT_COVER_EXTENSION: string = 'jpg';
/** Default book extension, matching `canonicalBookFilePath`'s own fallback. */
const DEFAULT_BOOK_EXTENSION: string = 'epub';

/** What a pass knows about one book's binaries on the server. */
interface RemoteBookState {
  /** The book folder that exists on the server, or an empty string. */
  folderName: string;
  state: RemoteBinaryState;
}

/** Which transfers actually landed, for the manifest. */
interface TransferOutcome {
  /** Book ids whose **book file** this pass put on the server. */
  uploaded: Set<string>;
  /** Book ids whose **cover** this pass put on the server. */
  coverUploaded: Set<string>;
  /** Book ids whose **book file** this pass pulled down. */
  downloaded: Set<string>;
}

/**
 * The v1 file phase.
 *
 * Constructed with the same `WebDavClient`, `WebDavConfig` and `FileStorage` the metadata
 * phase uses, so a pass cannot move binaries through a different credential set or into a
 * different sandbox than the one the metadata went through.
 *
 * `V1FileRunner` is declared in `./BinarySync` and implemented **explicitly** here: ArkTS has
 * no structural typing (`arkts-no-structural-typing`), so a class that merely looks right is
 * not assignable to the interface the engine holds. The interface lives in that shared leaf
 * module because the engine and this phase must not import each other at runtime.
 */
export class V1FilePhase implements V1FileRunner {
  private readonly client: WebDavClient;
  private readonly config: WebDavConfig;
  private readonly books: Books;
  private readonly storage: FileStorage;
  /**
   * The shared transfer executor, also used by the v2 engine.
   *
   * Reused rather than reimplemented because the parts that are hard — promoting a
   * download through a temporary file so an interrupted transfer never looks complete,
   * throttling per-chunk byte reports, choosing a content type — are already written and
   * already audited there. What is *not* reused is that class's manifest construction,
   * which is where the v2 `filePath` defect lived; the rules differ per protocol and this
   * module owns its own.
   */
  private readonly transfers: FileStorageRunner;

  constructor(
    client: WebDavClient,
    config: WebDavConfig,
    books: Books,
    storage: FileStorage,
  ) {
    this.client = client;
    this.config = config;
    this.books = books;
    this.storage = storage;
    this.transfers = new FileStorageRunner(client, config, books, storage);
  }

  /** Map a logical protocol path onto the user's configured remote root. */
  private path(logicalPath: string): string {
    return resolveRemotePath(
      { baseUrl: this.config.url, remoteRoot: this.config.remoteRoot },
      logicalPath,
    );
  }

  // ---------------------------------------------------------------------------
  // Remote layout
  // ---------------------------------------------------------------------------

  /**
   * Create the directory skeleton this phase writes into.
   *
   * This is `ensureRemoteLayout` extended for the file tree: v1's metadata engine creates
   * `/readany/sync`, and this creates `/readany/data`, the `books` root, and the two
   * legacy roots.
   *
   * **MKCOL only.** `WebDavClient.ensureDirectory` treats 405 / already-exists as success,
   * so re-running it is free, and nothing here enumerates or removes anything — an
   * "empty this directory first" step is precisely the shape that would grow into
   * v1.3.6's `cleanupRemoteOrphans`.
   *
   * `/readany/data/file` and `/readany/data/cover` are created even though this client
   * writes nothing into them: the released ReadAny clients still read the legacy layout,
   * and a directory that already exists costs one PROPFIND/405. Creating a directory is
   * not a migration — nothing is moved into or out of them here.
   */
  async ensureRemoteLayout(): Promise<void> {
    try {
      await this.client.ensureDirectory(this.path(REMOTE_DATA));
      await this.client.ensureDirectory(this.path(REMOTE_BOOKS_ROOT));
      await this.client.ensureDirectory(this.path(REMOTE_FILES));
      await this.client.ensureDirectory(this.path(REMOTE_COVERS));
    } catch (err) {
      throw new InkBoatError(
        SyncErrorKind.NETWORK,
        `无法创建远端书籍目录，请检查存储服务配置和权限：${String(err)}`,
      );
    }
  }

  /**
   * Create one book's folder. MKCOL only; already-exists is success.
   *
   * Called per book, before that book's transfers, rather than eagerly for every book in
   * the library. A pass that uploaded nothing would otherwise create a folder per book on
   * every run, which is a write storm that changes nothing.
   */
  private async ensureBookFolder(folderName: string): Promise<void> {
    try {
      await this.client.ensureDirectory(this.path(`${REMOTE_BOOKS_ROOT}/${folderName}`));
    } catch (err) {
      // A folder that cannot be created is reported as a NETWORK error so the engine's
      // per-transfer catch can count it and move on, rather than aborting the phase.
      throw new InkBoatError(
        SyncErrorKind.NETWORK,
        `无法创建书籍目录 ${folderName}：${String(err)}`,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // The pass
  // ---------------------------------------------------------------------------

  async runFilePhase(
    options: BinarySyncOptions,
    onProgress?: V1FileProgressFn,
  ): Promise<V1FileCounts> {
    try {
      return await this.runFilePhaseBody(options, onProgress);
    } catch (err) {
      // A phase-level failure — the remote `books` root could not be listed, the database
      // read failed, the manifest could not be written — is **counted, not thrown**. The
      // metadata half of this pass has already succeeded and its result is real; losing it
      // because a file could not move would misreport the pass and lose the merge. The
      // engine treats these counts as the pass's file outcome, so the user still sees that
      // something did not work, and the next pass retries it.
      const message: string = err instanceof Error ? err.message : String(err);
      hilog.error(DOMAIN, TAG, 'file phase failed: %{public}s', message);
      const failed: V1FileCounts = emptyV1FileCounts();
      failed.failed = 1;
      failed.error = message;
      // Also recorded as the first failure: a phase that stopped before any transfer ran
      // is exactly the case a bare count cannot describe, and the summary would otherwise
      // report "文件已是最新" for a pass that moved nothing because it could not start.
      failed.firstFailure = message;
      return failed;
    }
  }

  /**
   * The body of one file phase. Wrapped by `runFilePhase`, which is the only caller.
   *
   * Order, and why:
   *
   *  1. create the remote skeleton;
   *  2. read the manifest — **fail closed** if it is present and unparseable, because the
   *     pass ends with a write to that same document;
   *  3. gather local state and scan the remote folders for what is actually there;
   *  4. plan, then run uploads and downloads;
   *  5. record which transfers landed, apply the status side effects;
   *  6. rewrite the manifest from *post-transfer* knowledge, carrying over entries for
   *     books this device does not have.
   *
   * A manifest failure at step 2 does not stop steps 3-5: uploading this device's books
   * and fetching missing covers is useful and destroys nothing. It stops step 6 only.
   */
  private async runFilePhaseBody(
    options: BinarySyncOptions,
    onProgress?: V1FileProgressFn,
  ): Promise<V1FileCounts> {
    const counts: V1FileCounts = emptyV1FileCounts();

    await this.ensureRemoteLayout();

    // --- the manifest, read before anything is written ------------------------
    let previous: RemoteFileManifest | undefined;
    try {
      previous = await this.loadManifest();
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      hilog.error(DOMAIN, TAG, 'refusing to rewrite an unreadable manifest: %{public}s', message);
      counts.manifestRefused = true;
      counts.manifestError = message;
    }

    // --- state ---------------------------------------------------------------
    const all: Book[] = await this.books.listAll();
    const live: Book[] = [];
    for (const book of all) {
      // The reference's own query is `WHERE deleted_at IS NULL`. Soft-deleted rows are
      // skipped so a tombstoned book is not re-uploaded, and — importantly — this is the
      // *only* thing the live set is used for. It never decides that something should be
      // removed: see the module comment.
      if (book.deletedAt === 0) {
        live.push(book);
      }
    }
    if (live.length === 0) {
      this.report(onProgress, '没有需要传输的书籍文件', 0, 0);
      return counts;
    }

    const remote: Map<string, RemoteBookState> = await this.scanRemoteBooks(live, previous);
    const state: BookBinaryInput[] = await this.gatherState(live, remote);
    const plan: BinarySyncPlan = planBinarySync(state, options);

    const total: number = plan.uploads.length + plan.downloads.length;
    let done: number = 0;
    this.report(
      onProgress,
      total === 0 ? '文件已是最新' : `共 ${total} 个文件`,
      0,
      total,
    );

    const outcome: TransferOutcome = {
      uploaded: new Set<string>(),
      coverUploaded: new Set<string>(),
      downloaded: new Set<string>(),
    };

    // Uploads first. Getting this device's own files onto the server is what makes the
    // metadata meaningful to peers, and it is the direction that lets the user free local
    // space later — the reference orders the two the same way.
    for (const task of plan.uploads) {
      const description: string = describeTransfer(task);
      const isCover: boolean = task.kind === TransferKind.COVER_UPLOAD;
      this.report(onProgress, `上传 ${description}`, done, total);
      let ok: boolean = false;
      let cause: string = '';
      try {
        await this.ensureBookFolder(bookFolderNameOf(state, task.bookId));
        ok = await this.transfers.runTask(task);
        if (!ok) {
          // `runTask` reports failure by returning `false` and logs the reason itself. The
          // reason is also carried into the summary, because a log line is not where a user
          // looks for "why did nothing sync".
          cause = `上传 ${description} 未完成`;
        }
      } catch (err) {
        cause = err instanceof Error ? err.message : String(err);
        hilog.warn(DOMAIN, TAG, 'upload failed for %{public}s: %{public}s',
          shortId(task.bookId), cause);
      }
      if (ok) {
        counts.uploaded++;
        // A cover upload and a book-file upload are different claims about the server, and
        // the manifest records them separately: a book whose cover uploaded but whose
        // file did not is still a book the server does not have.
        if (isCover) {
          outcome.coverUploaded.add(task.bookId);
        } else {
          outcome.uploaded.add(task.bookId);
        }
      } else {
        counts.failed++;
        recordFirstFailure(counts, cause);
      }
      done++;
      this.report(onProgress, ok ? `已上传 ${description}` : `上传失败 ${description}`, done, total);
    }

    for (const task of plan.downloads) {
      const description: string = describeTransfer(task);
      this.report(onProgress, `下载 ${description}`, done, total);
      let ok: boolean = false;
      let cause: string = '';
      try {
        ok = await this.transfers.runTask(task);
        if (!ok) {
          cause = `下载 ${description} 未完成`;
        }
      } catch (err) {
        cause = err instanceof Error ? err.message : String(err);
        hilog.warn(DOMAIN, TAG, 'download failed for %{public}s: %{public}s',
          shortId(task.bookId), cause);
      }
      if (ok) {
        counts.downloaded++;
        outcome.downloaded.add(task.bookId);
      } else {
        counts.failed++;
        recordFirstFailure(counts, cause);
      }
      done++;
      this.report(onProgress, ok ? `已下载 ${description}` : `下载失败 ${description}`, done, total);
    }

    if (counts.failed > 0) {
      // One line naming the first distinct reason, so "失败 18" is never the whole story.
      // The per-transfer detail is on `InkBoatStorage`'s warn lines.
      hilog.warn(DOMAIN, TAG,
        'file phase finished with %{public}d failure(s); first reason: %{public}s',
        counts.failed, counts.firstFailure.length > 0 ? counts.firstFailure : '(not recorded)');
    }

    await this.transfers.markTransferred(transferredIds(outcome), uploadedIds(outcome));
    // Which books this pass downloaded is recorded *inside* the executor, at the moment each
    // promotion succeeded, and `applyStatusChanges` writes it into the row. Nothing is done
    // with the paths here on purpose: re-deriving a destination from `state` would ask a row
    // that arrived from a peer — whose `file_path` may be empty, which is why it is `remote` —
    // to say where a file it does not have should go. See
    // `FileStorageRunner.markDownloadedBooksLocal`.
    await this.transfers.applyStatusChanges(plan);

    if (counts.manifestRefused) {
      // The transfers above are already on disk and are the useful part of this pass; the
      // manifest is what is skipped, and the reason travels with it.
      hilog.warn(DOMAIN, TAG, 'manifest not rewritten: %{public}s', counts.manifestError);
      return counts;
    }
    if (previous === undefined) {
      // Unreachable in practice: `loadManifest` either returns a manifest or throws, and
      // the throw is caught above. Spelled out rather than `previous!` so a future edit
      // cannot introduce a silent dereference.
      return counts;
    }

    const next: RemoteFileManifest = this.buildManifest(state, remote, outcome, Date.now());
    // Keep entries for books this device does not have. Another device may own them, and
    // dropping them is what makes a manifest untrustworthy for everybody.
    previous.books.forEach((entry: ManifestEntry, bookId: string): void => {
      if (!next.books.has(bookId)) {
        next.books.set(bookId, entry);
      }
    });
    await this.saveManifest(next);
    return counts;
  }

  // ---------------------------------------------------------------------------
  // Manifest
  // ---------------------------------------------------------------------------

  /**
   * Read `/readany/data/file-manifest.json`.
   *
   * Delegated to `FileStorageRunner.loadManifest`, which is the one reader already fixed
   * to keep the three outcomes apart and to **throw** on an unparseable document rather
   * than return an empty manifest. Sharing it here means the rule cannot drift between the
   * two protocols, and there is deliberately no lenient reader in this module.
   */
  private async loadManifest(): Promise<RemoteFileManifest> {
    return await this.transfers.loadManifest();
  }

  /**
   * Write the manifest.
   *
   * `REMOTE_DATA` is re-ensured first because a manifest write is the one write that can
   * happen after a long transfer phase, which is long enough for a proxy to have torn the
   * directory down.
   */
  private async saveManifest(manifest: RemoteFileManifest): Promise<void> {
    await this.client.ensureDirectory(this.path(REMOTE_DATA));
    const wire: Record<string, Object> = manifestToWire(manifest, Date.now());
    await this.client.putText(
      this.path(REMOTE_FILE_MANIFEST),
      JSON.stringify(wire),
      'application/json',
    );
  }

  /**
   * Build the manifest from **post-transfer** knowledge.
   *
   * The two rules, restated where they are implemented:
   *
   *  - `filePath` is written only when the file is known to be on the server — either the
   *    remote scan found it, or this pass's `PUT` reported success. `input.local.fileExists`
   *    is deliberately **not** part of the test: a local file whose upload failed would
   *    otherwise be advertised, and every client would then believe the book is present
   *    while the server has nothing. ReadAny trusts this document, so the cost of that lie
   *    is a book that is permanently missing everywhere.
   *  - `folderName` is always written, and every optional field is omitted when empty,
   *    matching the reference writer byte for byte (`sync-files.ts:867-890`).
   */
  private buildManifest(
    state: BookBinaryInput[],
    remote: Map<string, RemoteBookState>,
    outcome: TransferOutcome,
    now: number,
  ): RemoteFileManifest {
    const manifest: RemoteFileManifest = emptyManifest();
    manifest.generatedAt = now;

    for (const input of state) {
      const bookId: string = input.bookId;
      const known: RemoteBookState | undefined = remote.get(bookId);
      const scanned: RemoteBinaryState | undefined = known === undefined ? undefined : known.state;

      const fileOnServer: boolean = outcome.uploaded.has(bookId)
        || (scanned !== undefined && scanned.fileExists);
      // A file found by the scan is on the server whether or not this pass also pulled it:
      // a download copies, it does not remove. A download that *failed* is not recorded,
      // and neither is one that was never planned. So the single question is whether the
      // server holds the file, and `scanned` is the answer for everything this pass did
      // not itself upload.
      //
      // The cover is tracked separately, and as itself: a cover upload landing says
      // nothing about the book file, so it must not be allowed to advertise `filePath`.
      const coverOnServer: boolean = outcome.coverUploaded.has(bookId)
        || (scanned !== undefined && scanned.coverExists);
      if (!fileOnServer && !coverOnServer) {
        continue;
      }

      const folderName: string = buildBookFolderName(bookId, input.title);
      const entry: ManifestEntry = emptyManifestEntry(folderName);

      if (fileOnServer) {
        entry.filePath = buildBookRemoteFile(bookId, input.title, input.format);
        entry.fileSize = sizeForFile(input, scanned, outcome, bookId);
      }
      if (coverOnServer) {
        const coverExt: string = input.coverExt.length > 0
          ? input.coverExt
          : DEFAULT_COVER_EXTENSION;
        entry.coverPath = buildBookRemoteCover(bookId, input.title, coverExt);
        entry.coverSize = sizeForCover(input, scanned, outcome, bookId);
        entry.coverHash = input.local.coverHash.length > 0
          ? input.local.coverHash
          : scanned === undefined ? '' : scanned.coverHash;
        entry.coverSourcePath = input.coverUrl;
      }
      entry.updatedAt = now;
      manifest.books.set(bookId, entry);
    }

    return manifest;
  }

  // ---------------------------------------------------------------------------
  // Remote state
  // ---------------------------------------------------------------------------

  /**
   * Find out what is actually on the server for each book.
   *
   * Two ways in, and which one is taken is a cost decision with a safety condition on it:
   *
   *  - **The manifest, when it describes every book this device has.** That is the
   *    reference's own test (`canUseRemoteFileManifest`, `sync-files.ts:792-812`) and the
   *    reason `file-manifest.json` exists at all: one small document instead of a PROPFIND
   *    per book. An entry with a `filePath` is a claim that the server holds the file, and
   *    it is only ever written after the upload that put it there succeeded or after a scan
   *    found it — see `buildManifest`. The moment a book is missing from the manifest the
   *    whole document is distrusted, because an absent entry is indistinguishable from
   *    "the server has nothing" and trusting it would re-upload a library.
   *  - **A folder scan otherwise.** One `Depth: 1` listing of `/readany/data/books` names
   *    the folders that exist, each is matched to a book id by the `-{id}` suffix (the
   *    reference's match, `sync-files.ts:720-729`, which works for any id shape), and then
   *    one `Depth: 1` listing **inside** each matched folder, which is the only thing that
   *    can say whether the book file and the cover are really there.
   *
   * The folder listing is what the v2 path approximates with "the folder exists, so the
   * book was uploaded at some point" (`FileStorageRunner.indexRemoteFolders`). That is
   * optimistic: a folder created by a failed upload makes the v2 planner skip the retry
   * and, through the manifest, tells every client the book is present. Here the scan is
   * definitive, so a failed upload is retried on the next pass instead of being believed.
   * It is also why the scan is the *fallback* rather than the default — it costs one
   * PROPFIND per book, and a library of a few hundred books would make every pass crawl.
   *
   * A folder that exists under a *stale* name (the title changed) is recorded but its
   * contents are reported as absent: the reference `MOVE`s the children into the new
   * folder, and this client does not. The book file is simply uploaded again into the
   * folder the current name implies, and the old folder is left alone.
   *
   * A listing failure is **not** treated as "the folder is empty". The listing throws, the
   * phase is caught one level up and counted, and nothing is claimed about the remote.
   * Reporting an unreachable folder as empty is how a client talks itself into uploading a
   * library it cannot see, or into believing a file is absent when it is there.
   */
  private async scanRemoteBooks(
    books: Book[],
    manifest: RemoteFileManifest | undefined,
  ): Promise<Map<string, RemoteBookState>> {
    if (manifest !== undefined) {
      const fromManifest: Map<string, RemoteBookState> | undefined =
        this.remoteStateFromManifest(books, manifest);
      if (fromManifest !== undefined) {
        return fromManifest;
      }
    }

    const found: Map<string, RemoteBookState> = new Map<string, RemoteBookState>();

    const rootEntries: RemoteResource[] = await this.client.safeListDir(
      this.path(REMOTE_BOOKS_ROOT),
    );
    const folderNames: string[] = [];
    for (const entry of rootEntries) {
      if (entry.isCollection && entry.name.length > 0) {
        folderNames.push(entry.name);
      }
    }
    // Logged before the match rather than after: "the root listing came back"
    // and "the root listing yielded folders" are different facts, and when nothing
    // matches, which of the two failed is the whole diagnosis. `WebDavClient.listDir`
    // logs the raw entry count and bodies that parse to zero; this line is what ties
    // that to the scan's own view of them.
    hilog.info(DOMAIN, TAG,
      'remote books root %{public}s: %{public}d listing(s), %{public}d collection(s)',
      this.path(REMOTE_BOOKS_ROOT), rootEntries.length, folderNames.length);
    if (folderNames.length === 0) {
      // Not fatal by itself — a first run against an empty server looks exactly like
      // this — but it is the single fact that explains "0 downloads" when the server
      // does hold books, so it is reported rather than left to be inferred.
      hilog.warn(DOMAIN, TAG,
        'remote books root %{public}s has no collection: nothing can be matched to a book id',
        this.path(REMOTE_BOOKS_ROOT));
    }

    // First pass: name matching, no network. `find` + `used` reproduces the reference's
    // match, which claims each folder for at most one book.
    const used: Set<string> = new Set<string>();
    const matched: Map<string, string> = new Map<string, string>();
    for (const book of books) {
      const suffix: string = `-${book.id}`;
      for (const name of folderNames) {
        if (used.has(name)) {
          continue;
        }
        if (name.length > suffix.length && name.endsWith(suffix)) {
          matched.set(book.id, name);
          used.add(name);
          break;
        }
      }
    }

    // Second pass: list the inside of each matched folder. Sequential on purpose: the
    // reference runs its migration at concurrency 3 to avoid 401 throttling on consumer
    // WebDAV providers (jianguoyun, some NAS), and a burst of PROPFINDs is exactly what
    // triggers it.
    let matchedFolders: number = 0;
    let listedFolders: number = 0;
    let foldersWithFile: number = 0;
    for (const book of books) {
      const folderName: string | undefined = matched.get(book.id);
      const state: RemoteBinaryState = unknownRemoteState();
      const expected: string = buildBookFolderName(book.id, book.title);
      if (folderName !== undefined) {
        matchedFolders++;
        const entries: RemoteResource[] = await this.client.listDir(
          this.path(`${REMOTE_BOOKS_ROOT}/${folderName}`),
        );
        listedFolders++;
        for (const entry of entries) {
          if (entry.isCollection) {
            continue;
          }
          // The stem is not checked against the title: a book file is identified by its
          // extension, so a file renamed by a peer is still the book. The reference's
          // download fallback scans a folder by extension for the same reason.
          if (isBookFileName(entry.name) && !state.fileExists) {
            state.fileExists = true;
            state.fileSize = entry.contentLength;
          } else if (isCoverFileName(entry.name) && !state.coverExists) {
            state.coverExists = true;
            state.coverSize = entry.contentLength;
          }
        }
        if (state.fileExists) {
          foldersWithFile++;
        }
        // Per-folder, because the two ways this can go wrong need different answers:
        // an empty `entries` means the listing is the problem (and `WebDavClient.listDir`
        // has already logged its body), while a non-empty one with no book extension
        // means the folder holds something this client does not recognise as the book —
        // a stem-only name, a format outside `BOOK_EXTENSIONS`, or a peer's temporary
        // file. Neither is inferable from the summary's counts.
        hilog.info(DOMAIN, TAG,
          'book %{public}s folder %{public}s: %{public}d entry(ies), file=%{public}s cover=%{public}s',
          shortId(book.id), folderName, entries.length,
          state.fileExists ? 'yes' : 'no', state.coverExists ? 'yes' : 'no');
      }
      // A folder under the current name is the only one whose contents are trusted; a
      // stale-named folder's files are not at the path this pass would write, so they are
      // reported as absent and the file is uploaded again.
      const atExpectedName: boolean = folderName !== undefined && folderName === expected;
      if (folderName !== undefined && !atExpectedName) {
        // Recorded the same way the reference's migration would find it, but stated out
        // loud: this client deliberately leaves the old folder alone, so the book file is
        // re-uploaded under the current name instead of being moved.
        hilog.info(DOMAIN, TAG,
          'book %{public}s lives in a stale-named folder (%{public}s, expected %{public}s); its contents are not trusted and the file will be uploaded again',
          shortId(book.id), folderName, expected);
      }
      const result: RemoteBookState = {
        folderName: folderName === undefined ? '' : folderName,
        state: atExpectedName ? state : unknownRemoteState(),
      };
      found.set(book.id, result);
    }

    hilog.info(DOMAIN, TAG,
      'remote scan: %{public}d book(s), %{public}d matched a folder, %{public}d listed, %{public}d reported a book file',
      books.length, matchedFolders, listedFolders, foldersWithFile);

    return found;
  }

  /**
   * Derive every book's remote state from the manifest, or `undefined` when it cannot be
   * trusted for that.
   *
   * The condition is the reference's: an entry for **every** book this device has. A manifest
   * that is missing one is worse than no manifest, because its absent entries read as "the
   * server has nothing" and the client would re-upload files it already has.
   *
   * `folderName` is carried through as it stands rather than recomputed from the title. A
   * folder is named from the title *at upload time*, so a book renamed since then still
   * lives in the folder the manifest names — and the manifest's `filePath` is what a peer
   * resolves, so answering with a title-derived folder would report the file absent and
   * upload a second copy under the new name.
   */
  private remoteStateFromManifest(
    books: Book[],
    manifest: RemoteFileManifest,
  ): Map<string, RemoteBookState> | undefined {
    const ids: string[] = [];
    for (const book of books) {
      ids.push(book.id);
    }
    if (!manifestCoversAll(manifest, ids)) {
      hilog.info(DOMAIN, TAG,
        'the manifest does not cover all %{public}d book(s); scanning the remote folders',
        ids.length);
      return undefined;
    }

    const found: Map<string, RemoteBookState> = new Map<string, RemoteBookState>();
    for (const book of books) {
      const entry: ManifestEntry | undefined = manifest.books.get(book.id);
      if (entry === undefined) {
        return undefined;
      }
      const state: RemoteBinaryState = unknownRemoteState();
      state.fileExists = entry.filePath.length > 0;
      state.fileSize = entry.fileSize;
      state.coverExists = entry.coverPath.length > 0;
      state.coverSize = entry.coverSize;
      state.coverHash = entry.coverHash;
      state.coverSourcePath = entry.coverSourcePath;
      const folderName: string = entry.folderName.length > 0
        ? entry.folderName
        : buildBookFolderName(book.id, book.title);
      found.set(book.id, { folderName: folderName, state: state });
    }
    return found;
  }

  // ---------------------------------------------------------------------------
  // Local state
  // ---------------------------------------------------------------------------

  /**
   * Gather what this device has, per book.
   *
   * The local cover path is taken from the row's `cover_url` when that is a file inside
   * the sandbox — the canonical `covers/{id}.{ext}` case and the `covers/{id}-custom-*`
   * case both land there — and from the canonical `covers/{id}.jpg` otherwise. Without
   * that second branch a book whose `cover_url` is an `http` URL (very common: it is what
   * the ReadAny scrapers write) would never have its locally extracted cover uploaded.
   */
  private async gatherState(
    books: Book[],
    remote: Map<string, RemoteBookState>,
  ): Promise<BookBinaryInput[]> {
    const out: BookBinaryInput[] = [];
    for (const book of books) {
      const relativeFilePath: string = canonicalBookFilePath(book.id, book.filePath, book.format);
      const format: string = formatOf(book, relativeFilePath);
      const localFilePath: string = `${this.storage.root()}/${relativeFilePath}`;

      const coverExt: string = book.coverUrl.length > 0 ? coverExtOf(book.coverUrl) : '';
      const localCoverPath: string = coverExt.length > 0
        ? this.localCoverPathOf(book, coverExt)
        : '';

      const local: LocalBinaryState = {
        fileExists: false,
        fileSize: 0,
        coverExists: false,
        coverSize: 0,
        coverHash: '',
      };
      const fileInfo = await this.storage.info(localFilePath);
      local.fileExists = fileInfo.exists;
      local.fileSize = fileInfo.size;
      if (localCoverPath.length > 0) {
        const coverInfo = await this.storage.info(localCoverPath);
        local.coverExists = coverInfo.exists;
        local.coverSize = coverInfo.size;
        if (coverInfo.exists) {
          // Hashed only when there is a local cover: a missing file has no hash, and the
          // change rule treats an empty hash as "no information".
          local.coverHash = await this.storage.hashOf(localCoverPath);
        }
      }

      const known: RemoteBookState | undefined = remote.get(book.id);
      out.push({
        bookId: book.id,
        title: book.title,
        format: format,
        coverUrl: book.coverUrl,
        coverExt: coverExt,
        localFilePath: localFilePath,
        localCoverPath: localCoverPath,
        local: local,
        remote: known === undefined ? unknownRemoteState() : known.state,
        folderName: buildBookFolderName(book.id, book.title),
        relativeFilePath: relativeFilePath,
      });
    }
    return out;
  }

  /** Absolute local path of a book's cover, preferring the row's own `cover_url`. */
  private localCoverPathOf(book: Book, coverExt: string): string {
    const canonical: string | null = canonicalBookCoverPath(book.id, book.coverUrl);
    if (canonical !== null && !/^https?:\/\//i.test(canonical) && canonical.length > 0) {
      return this.absoluteOf(canonical);
    }
    return this.storage.coverPath(book.id, coverExt);
  }

  /**
   * Turn a stored relative path into an absolute one.
   *
   * Legacy rows carry either a bare relative path, a `file://` URI, or an already absolute
   * sandbox path depending on which client wrote them, so all three are handled rather
   * than assuming the current format.
   */
  private absoluteOf(relativeOrAbsolute: string): string {
    if (relativeOrAbsolute.startsWith('file://')) {
      return relativeOrAbsolute.substring('file://'.length);
    }
    if (relativeOrAbsolute.startsWith('/')) {
      return relativeOrAbsolute;
    }
    return `${this.storage.root()}/${relativeOrAbsolute}`;
  }

  private report(
    onProgress: V1FileProgressFn | undefined,
    message: string,
    completed: number,
    total: number,
  ): void {
    if (onProgress === undefined) {
      return;
    }
    onProgress(message, completed, total);
  }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** First eight characters of an id, for a log line. */
function shortId(id: string): string {
  return id.length > 8 ? id.substring(0, 8) : id;
}

/**
 * Keep the first transfer failure's reason, and only the first.
 *
 * The first is the representative one: it is the one that happened before any later
 * retry could succeed or fail for a different reason, and it is the one a report can
 * quote without inventing a summary of 18 exceptions. Later failures are not folded in
 * — a counter already says how many there were, and a concatenation of 18 messages is
 * not something anyone reads.
 *
 * An empty `reason` never overwrites a recorded one, so a `false` returned without a
 * message cannot blank out a real cause recorded earlier.
 */
function recordFirstFailure(counts: V1FileCounts, reason: string): void {
  if (counts.firstFailure.length === 0 && reason.length > 0) {
    counts.firstFailure = reason;
  }
}

// The helper that used to live here mapped a downloaded book id back to the
// sandbox-relative path via `BookBinaryInput.relativeFilePath` — the path this pass *would*
// use, not the one the transfer *did* use. A book whose row arrived from a peer with an empty
// `file_path` (the peer's upload strips it, and the row is `remote` because the file is not
// here yet) had no answer, and its caller's `continue` then left the book remote with nothing
// logged. The destination is now recorded by the transfer itself and written by
// `FileStorageRunner.markDownloadedBooksLocal`, which both engines reach through
// `applyStatusChanges`; there is deliberately no second place that could disagree.

/** Every book id that moved in either direction. */
function transferredIds(outcome: TransferOutcome): string[] {
  const ids: string[] = [];
  outcome.uploaded.forEach((id: string): void => {
    ids.push(id);
  });
  outcome.downloaded.forEach((id: string): void => {
    if (!outcome.uploaded.has(id)) {
      ids.push(id);
    }
  });
  return ids;
}

/** The book ids whose bytes this pass put on the server. */
function uploadedIds(outcome: TransferOutcome): string[] {
  const ids: string[] = [];
  outcome.uploaded.forEach((id: string): void => {
    ids.push(id);
  });
  outcome.coverUploaded.forEach((id: string): void => {
    if (!outcome.uploaded.has(id)) {
      ids.push(id);
    }
  });
  return ids;
}

/** The folder a task belongs to, taken from the gathered input rather than re-derived. */
function bookFolderNameOf(state: BookBinaryInput[], bookId: string): string {
  for (const input of state) {
    if (input.bookId === bookId) {
      return input.folderName;
    }
  }
  return '';
}

/** A human-readable name for one transfer, for the live progress line. */
function describeTransfer(task: TransferTask): string {
  const title: string = task.title === undefined || task.title.length === 0
    ? shortId(task.bookId)
    : task.title;
  if (task.kind === TransferKind.COVER_UPLOAD || task.kind === TransferKind.COVER_DOWNLOAD) {
    return `${title} 封面`;
  }
  return title;
}

/**
 * The size to record for a book file.
 *
 * Order: what this pass's own `PUT` moved, then what the server reported, then the local
 * file. A downloaded book is deliberately **not** read from `input.local.fileSize` first:
 * the local snapshot was taken before the transfer, so its size is the stale one (or zero
 * for a book that had no file at all). Recording 0 there makes every later size comparison
 * look like a change.
 */
function sizeForFile(
  input: BookBinaryInput,
  scanned: RemoteBinaryState | undefined,
  outcome: TransferOutcome,
  bookId: string,
): number {
  if (outcome.uploaded.has(bookId)) {
    return input.local.fileSize;
  }
  if (scanned !== undefined && scanned.fileSize > 0) {
    return scanned.fileSize;
  }
  return input.remote.fileSize;
}

/** The size to record for a cover, by the same rule as the book file. */
function sizeForCover(
  input: BookBinaryInput,
  scanned: RemoteBinaryState | undefined,
  outcome: TransferOutcome,
  bookId: string,
): number {
  if (outcome.uploaded.has(bookId)) {
    return input.local.coverExists ? input.local.coverSize : input.remote.coverSize;
  }
  if (scanned !== undefined && scanned.coverSize > 0) {
    return scanned.coverSize;
  }
  return input.remote.coverSize;
}

/** A book's format as a usable extension. */
function formatOf(book: Book, relativeFilePath: string): string {
  const dot: number = relativeFilePath.lastIndexOf('.');
  if (dot >= 0 && dot < relativeFilePath.length - 1) {
    return relativeFilePath.substring(dot + 1).toLowerCase();
  }
  return book.format.length > 0 ? book.format : DEFAULT_BOOK_EXTENSION;
}

/** Extension of a local `cover_url`, or `jpg`. Matches the reference's `getExt`. */
function coverExtOf(coverUrl: string): string {
  const trimmed: string = coverUrl.replace(/\/+$/, '');
  const parts: string[] = trimmed.split('/');
  const name: string = parts.length > 0 ? parts[parts.length - 1] : '';
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return DEFAULT_COVER_EXTENSION;
  }
  const ext: string = name.substring(dot + 1).toLowerCase();
  return ext.length > 0 ? ext : DEFAULT_COVER_EXTENSION;
}

/**
 * Make an identifier safe to use as a single path segment.
 *
 * Book ids are generated UUIDs and are already safe, but a row that arrived from a peer
 * carries whatever that peer wrote, and a `/` in it would silently turn a temporary file
 * name into a nested path that `tempPath` does not create. Also used by the v2 runner;
 * duplicated here only because it is four lines and this module owns its own copy of the
 * rule.
 */
export function sanitizeForPath(value: string): string {
  const cleaned: string = value.replace(/[/\\:*?"<>|\s]/g, '_');
  return cleaned.length > 0 ? cleaned.substring(0, 64) : 'unknown';
}
