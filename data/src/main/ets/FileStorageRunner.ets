/**
 * Concrete binary-sync runner: file I/O plus the WebDAV transfers.
 *
 * This is the glue the engine deliberately does not contain. `SyncEngine` plans
 * and counts; this knows about `@ohos.file.fs`, `file-manifest.json`, and the
 * shape of the remote tree.
 *
 * Remote state comes from the manifest when it can be trusted, and from a folder
 * listing when it cannot. The manifest is a *hint*, not a source of truth: it is
 * written by whichever device last synced, and a peer that has never uploaded a
 * given book will simply not mention it. Trusting a partial manifest would read
 * every absent entry as "the server has nothing", and the client would re-upload
 * files it already has — which is exactly the failure the fallback avoids.
 */

import {
  buildBookFolderName,
  isCoverFileName,
  JsonDocument,
  JsonReadOutcome,
  parseBookFolderName,
  readJsonDocument,
  REMOTE_BOOKS_ROOT,
  REMOTE_DATA,
  REMOTE_FILE_MANIFEST,
  resolveRemotePath,
  utf8Decode,
  WebDavClient,
} from 'sync';
import type { RemoteResource, WebDavConfig } from 'sync';
import { TRANSFER_TIMEOUT_MS } from 'sync';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InkBoatError, SyncErrorKind } from 'core';

import type { Book } from './Types';
import type {
  BinarySyncPlan,
  BookBinaryInput,
  LocalBinaryState,
  ManifestEntry,
  RemoteBinaryState,
  RemoteFileManifest,
  TransferTask,
} from './BinarySync';
import {
  emptyManifest,
  emptyManifestEntry,
  manifestFromWire,
  manifestToWire,
  TransferKind,
  unknownRemoteState,
} from './BinarySync';
import { Books } from './Books';
import { FileStorage } from './FileStorage';
import { canonicalBookFilePath, resolveBookExtension } from './SyncV1';
import type { BinaryBookInput, BinarySyncRunner } from './SyncEngine';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatStorage';

/**
 * Shortest gap between two byte reports from one transfer, in ms.
 *
 * The streaming reader fires per received chunk — hundreds of times for a single book, and
 * thousands for a large one. That is far more often than a progress line can be read, and
 * each report allocates an object the UI layer would have to coalesce anyway, so the
 * throttle is applied here at the source of the storm. 120 ms is roughly eight updates a
 * second: visibly live, and cheap.
 *
 * Uploads never reach this path at all — see `runTask`.
 */
const BYTE_REPORT_MIN_INTERVAL_MS: number = 120;

/**
 * The extension of the file this book is actually stored as.
 *
 * **Not** `book.format`. ReadAny records the *source* format in that column but stores
 * `txt` and `umd` imports converted, as `books/{id}.epub`
 * (`packages/app/src/stores/library-store.ts:404-405` against `:439` and `:465`), and a
 * device was observed holding 15 rows with `format = 'txt'` and no `.txt` file at all.
 * `resolveBookExtension` is the one rule for this in the app: it prefers the extension of
 * the row's own `file_path` and only falls back to `format`.
 *
 * The result is carried as `BookBinaryInput.format`, which every consumer treats as the
 * file's extension and nothing else: `planBinarySync` builds the remote name from it
 * (`BinarySync.ets:348`) and `buildManifest` builds the manifest's `filePath` from it.
 * That also makes this path agree with the v1 phase, which already derives the extension
 * from the canonical path (`V1FilePhase.ets:799-800`) and therefore already uploads
 * `{title}.epub` for such a row.
 */
function fileExtensionOf(book: Book): string {
  return resolveBookExtension(book.filePath, book.format);
}

/** Cover extension from a local `cover_url`, or `jpg`. */
function coverExtOf(coverUrl: string): string {
  const trimmed: string = coverUrl.replace(/\/+$/, '');
  const parts: string[] = trimmed.split('/');
  const name: string = parts.length > 0 ? parts[parts.length - 1] : '';
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return 'jpg';
  }
  const ext: string = name.substring(dot + 1).toLowerCase();
  return ext.length > 0 ? ext : 'jpg';
}

/** Content type for an upload, best effort. */
function contentTypeFor(ext: string): string {
  const lower: string = ext.toLowerCase();
  if (lower === 'jpg' || lower === 'jpeg') {
    return 'image/jpeg';
  }
  if (lower === 'png') {
    return 'image/png';
  }
  if (lower === 'webp') {
    return 'image/webp';
  }
  if (lower === 'gif') {
    return 'image/gif';
  }
  if (lower === 'epub') {
    return 'application/epub+zip';
  }
  if (lower === 'pdf') {
    return 'application/pdf';
  }
  return 'application/octet-stream';
}

export class FileStorageRunner implements BinarySyncRunner {
  private readonly client: WebDavClient;
  private readonly config: WebDavConfig;
  private readonly books: Books;
  private readonly storage: FileStorage;
  /** Books seen in the last `listBooks`, so state queries do not re-read them. */
  private lastBooks: Book[] = [];

  /**
   * Books whose binaries were transferred successfully in the current pass.
   *
   * The recorded state was gathered before the transfers, so these are the books
   * whose local facts are now stale in the *optimistic* direction: a downloaded
   * book has a file and a size that the earlier snapshot does not know about.
   */
  private transferred: Set<string> = new Set<string>();

  /**
   * Books whose **book file upload** this pass confirmed.
   *
   * Distinct from `transferred` on purpose, and the distinction is the whole reason this
   * field exists. `runTask` returns `true` only after the `PUT` completes, so membership
   * here means the server holds the file. A book that was merely *planned* for upload, or
   * whose upload failed, must not be in this set — see `buildManifest`.
   */
  private uploaded: Set<string> = new Set<string>();

  /**
   * The destination each successful **book-file** download of this pass actually wrote.
   *
   * Recorded by `runTask` at the one moment the fact is certain — after `move` promoted the
   * temporary file to `task.localPath` — and consumed by `applyStatusChanges`, which stores
   * the sandbox-relative form in `file_path` and sets `sync_status = 'local'`.
   *
   * The path is taken from the transfer rather than re-derived from the row, and that is the
   * point: `planBinarySync` decides downloads from the state gathered *before* the transfers,
   * so the row for a book being downloaded has no local file and may have an empty
   * `file_path` — a row that arrived from a peer is written with `file_path` describing the
   * peer's sandbox, or with nothing at all. A path re-derived from such a row is exactly the
   * thing that cannot be trusted, while the destination `runTask` just promoted to is a fact.
   */
  private downloadedDestinations: Map<string, string> = new Map<string, string>();

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
  }

  /**
   * Record this pass's successes.
   *
   * `transferred` is every book that moved in either direction (it drives the "size is now
   * the local one" correction). `uploaded` is the book files whose `PUT` was confirmed —
   * that is, the only books this pass can assert are on the server.
   */
  markTransferred(bookIds: string[], uploadedBookIds: string[]): void {
    this.transferred = new Set<string>();
    for (const id of bookIds) {
      this.transferred.add(id);
    }
    this.uploaded = new Set<string>();
    for (const id of uploadedBookIds) {
      this.uploaded.add(id);
    }
  }

  /** Map a logical protocol path onto the user's configured remote root. */
  private path(logicalPath: string): string {
    return resolveRemotePath(
      { baseUrl: this.config.url, remoteRoot: this.config.remoteRoot },
      logicalPath,
    );
  }

  async ensureLocalLayout(): Promise<void> {
    await this.storage.ensureLayout();
  }

  async listBooks(): Promise<BinaryBookInput[]> {
    this.lastBooks = await this.books.listAll();
    const out: BinaryBookInput[] = [];
    for (const book of this.lastBooks) {
      out.push({
        bookId: book.id,
        title: book.title,
        format: fileExtensionOf(book),
        coverUrl: book.coverUrl,
      });
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Remote state
  // ---------------------------------------------------------------------------

  /**
   * Read `/readany/data/file-manifest.json`.
   *
   * Three outcomes, kept apart deliberately, because the caller's next act is a *write*:
   *
   *  - **absent** (a 404) — the normal first run. An empty manifest is returned, and
   *    `manifestCoversAll` then reports it as untrustworthy, so the folder-listing
   *    fallback supplies the real remote state. There was nothing to lose.
   *  - **parsed** — returned as read.
   *  - **unparseable** — a body arrived and is not a JSON object. This is **thrown**, not
   *    read as empty. The manifest is rewritten at the end of every binary pass, and
   *    rebuilding it from this device's own view would drop every entry it held for a book
   *    this device does not know about. ReadAny behaves the same way: its `getJSON` throws
   *    on a parse failure and the pass aborts (`webdav-client.ts:691-704`,
   *    `per-book-sync.ts:1072-1084`). The engine already treats a failure of the binary
   *    phase as non-fatal and counted, so the metadata pass that ran before it keeps its
   *    result and the user is told the file phase did not run.
   *
   * The previous version collapsed the last two into "return an empty manifest", with the
   * note that the folder-listing fallback covers both. That is true of the *plan* and false
   * of the *write*: the pass ends by PUTting a manifest built from what it gathered, so an
   * unreadable document was replaced by a narrower one.
   */
  async loadManifest(): Promise<RemoteFileManifest> {
    let text: string = '';
    try {
      const bytes: Uint8Array = await this.client.getBytes(this.path(REMOTE_FILE_MANIFEST));
      text = utf8Decode(bytes);
    } catch (err) {
      if (err instanceof InkBoatError && err.kind === SyncErrorKind.NOT_FOUND) {
        return emptyManifest();
      }
      // Re-wrapped rather than forwarded: ArkTS rejects a bare `throw err` from a catch
      // clause (`arkts-limited-throw`), and an already-classified error keeps its kind.
      const wrapped: InkBoatError = err instanceof InkBoatError
        ? err
        : new InkBoatError(SyncErrorKind.NETWORK, `读取 ${REMOTE_FILE_MANIFEST} 失败`);
      throw wrapped;
    }

    const document: JsonDocument = readJsonDocument(text);
    if (document.outcome === JsonReadOutcome.UNPARSEABLE) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        unparseableManifestMessage(document.excerpt),
      );
    }
    if (document.record === undefined) {
      return emptyManifest();
    }
    return manifestFromWire(document.record);
  }

  async saveManifest(manifest: RemoteFileManifest): Promise<void> {
    await this.client.ensureDirectory(this.path(REMOTE_DATA));
    const wire: Record<string, Object> = manifestToWire(manifest, Date.now());
    await this.client.putText(this.path(REMOTE_FILE_MANIFEST), JSON.stringify(wire), 'application/json');
  }

  /**
   * Gather local and remote state for every book.
   *
   * The manifest is used only when it mentions every book this device has.
   * Otherwise the remote tree is probed: one `Depth: 1` listing of the `books`
   * root identifies which book folders exist, and a folder is only opened when
   * this device cannot already see a local cover to upload.
   *
   * That last condition is what keeps the fallback cheap. A cover only matters to
   * the plan when there is a local one to push — without a local cover the plan
   * never uploads, and it only downloads when the manifest (or this probe) says
   * the server has one. So on a library where covers were already synced, the
   * per-folder listing never happens.
   */
  async gatherState(books: BinaryBookInput[]): Promise<BookBinaryInput[]> {
    const manifest: RemoteFileManifest = await this.loadManifest();
    const trustManifest: boolean = manifestCoversEveryBook(manifest, books);

    // Only computed when the manifest cannot be trusted.
    const listed: Map<string, RemoteBinaryState> | undefined = trustManifest
      ? undefined
      : await this.indexRemoteFolders();

    const out: BookBinaryInput[] = [];
    for (const input of books) {
      const book: Book | undefined = this.findBook(input.bookId);
      if (book === undefined) {
        continue;
      }

      const format: string = input.format;
      const localFilePath: string = book.filePath.length > 0
        ? this.absoluteOf(book.filePath)
        : this.storage.bookPath(book.id, format);

      const coverExt: string = book.coverUrl.length > 0 ? coverExtOf(book.coverUrl) : '';
      const localCoverPath: string = coverExt.length > 0
        ? this.absoluteOf(book.coverUrl, this.storage.coverPath(book.id, coverExt))
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
          // Hashed only when there is a local cover: a missing file has no hash,
          // and the change rule treats an empty hash as "no information".
          local.coverHash = await this.storage.hashOf(localCoverPath);
        }
      }

      let remote: RemoteBinaryState;
      if (trustManifest) {
        const entry: ManifestEntry | undefined = manifest.books.get(book.id);
        remote = entry !== undefined ? remoteStateFromEntry(entry, coverExt) : unknownRemoteState();
      } else {
        remote = listed !== undefined && listed.has(book.id)
          ? (listed.get(book.id) as RemoteBinaryState)
          : unknownRemoteState();
        // A present folder means the book file was uploaded at some point; its
        // contents decide whether the cover is there too.
        if (remote.fileExists && coverExt.length > 0 && local.coverExists) {
          const folderName: string = buildBookFolderName(book.id, book.title);
          if (await this.hasCoverInFolder(folderName)) {
            remote.coverExists = true;
          }
        }
      }

      out.push({
        bookId: book.id,
        title: book.title,
        format: format,
        coverUrl: book.coverUrl,
        coverExt: coverExt,
        localFilePath: localFilePath,
        localCoverPath: localCoverPath,
        local: local,
        remote: remote,
        folderName: buildBookFolderName(book.id, book.title),
        relativeFilePath: canonicalBookFilePath(book.id, book.filePath, format),
      });
    }
    return out;
  }

  /**
   * Index the remote `books` root by book id.
   *
   * One `Depth: 1` PROPFIND lists the folders; a second, `Depth: 1` listing per
   * folder would be needed for sizes, so sizes are left at zero here. That is safe
   * because size is only a *hint* in the plan — the authoritative signals for
   * covers are the hash and the recorded source path, and for book files only
   * presence matters.
   */
  private async indexRemoteFolders(): Promise<Map<string, RemoteBinaryState>> {
    const index: Map<string, RemoteBinaryState> = new Map<string, RemoteBinaryState>();
    const entries: RemoteResource[] = await this.client.safeListDir(this.path(REMOTE_BOOKS_ROOT));
    for (const entry of entries) {
      if (!entry.isCollection) {
        continue;
      }
      const bookId: string = parseBookFolderName(entry.name);
      if (bookId.length === 0) {
        continue;
      }
      // Optimistic: the folder exists, so the book was uploaded at some point.
      // A missing file inside a present folder would surface as a failed download
      // rather than a silent skip, which is the more diagnosable outcome.
      const state: RemoteBinaryState = unknownRemoteState();
      state.fileExists = true;
      index.set(bookId, state);
    }
    return index;
  }

  /** Is there a cover file inside a book folder? */
  private async hasCoverInFolder(folderName: string): Promise<boolean> {
    const entries: RemoteResource[] = await this.client.safeListDir(
      this.path(`${REMOTE_BOOKS_ROOT}/${folderName}`),
    );
    for (const entry of entries) {
      if (!entry.isCollection && isCoverFileName(entry.name)) {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Transfers
  // ---------------------------------------------------------------------------

  /**
   * Perform one transfer.
   *
   * Downloads land in a temporary file and are promoted only on success, so an
   * interrupted transfer never leaves a partial file that looks complete. A
   * half-written EPUB is indistinguishable from a corrupt one to every later
   * reader, and would be treated as "the local copy exists" forever.
   *
   * `onBytes` reports a **download's** byte count as it arrives, because that is the only
   * direction this app can measure: `WebDavClient.getToFile` streams the body and hands
   * back each chunk, while an upload is one `PUT` of an in-memory buffer with no per-chunk
   * hook at any layer. So an upload calls nothing here and its progress is the file counter
   * the engine reports around it — the honest answer rather than a fabricated bar.
   *
   * `total` is -1 when the server sent no `Content-Length`; it is forwarded unchanged so the
   * caller can tell "unknown size" from "zero bytes".
   */
  async runTask(
    task: TransferTask,
    onBytes?: (received: number, total: number) => void,
  ): Promise<boolean> {
    const remotePath: string = this.path(task.remotePath);
    try {
      if (task.kind === TransferKind.BOOK_UPLOAD || task.kind === TransferKind.COVER_UPLOAD) {
        const bytes: Uint8Array = await this.storage.readBytes(task.localPath);
        const ext: string = extensionOfRemote(task.remotePath);
        await this.client.putBytes(remotePath, bytes, contentTypeFor(ext));
        return true;
      }

      // Downloads stream straight to a temporary file, then promote. Reading the
      // body into memory first (as `getBytes` does) would need one contiguous buffer
      // the size of the book, and an out-of-memory kill is not a catchable error.
      //
      // The temporary path is derived from the task rather than generated here so
      // the catch below can remove it; ArkTS forbids re-throwing a caught value, so
      // there is no inner catch to clean up in.
      const temp: string = this.tempPathFor(task, 'download');
      // Both directories the download touches, created before either write.
      //
      // This is the only place that knows the destination it is about to open, so it is the
      // only place the guarantee holds. `ensureLayout` creates `books/`, `covers/` and `tmp/`,
      // but it is called by the v2 engine and by the importer — never by the v1 file phase —
      // and a fresh install whose library arrived by *sync* has never imported anything. That
      // is the reported failure: 18 transfers, every one ENOENT on a directory that had never
      // been created. Doing it here covers both protocols because both funnel through this
      // executor (`V1FilePhase` holds one; `SyncEngine` holds the other), and it covers the
      // download's temporary path as well as its destination — `fileIo.open` creates the file,
      // never the directory above it, and the temporary path is opened first.
      //
      // Derived from the paths rather than from a fixed list of directory names: a fixed list
      // would have to be kept in step with every path builder in the codebase, and it would
      // still miss a `localPath` that came from a row's own `file_path`.
      await this.storage.ensureParentOf(temp);
      await this.storage.ensureParentOf(task.localPath);
      // Throttled at the source. `getToFile` fires its callback once per received chunk,
      // which for a large book is thousands of calls per file; forwarding every one would
      // allocate a progress object per chunk for no visible gain. `Date.now()` is the only
      // clock read on this path, and the final report is always delivered — a throttled
      // *last* update would leave the bar short of the end.
      let lastReportAt: number = 0;
      let lastReceived: number = 0;
      const report = (received: number, total: number): void => {
        lastReceived = received;
        if (onBytes === undefined) {
          return;
        }
        const finished: boolean = total > 0 && received >= total;
        const now: number = Date.now();
        if (!finished && now - lastReportAt < BYTE_REPORT_MIN_INTERVAL_MS) {
          return;
        }
        lastReportAt = now;
        onBytes(received, total);
      };

      await this.client.getToFile(remotePath, temp, TRANSFER_TIMEOUT_MS, report);
      await this.storage.move(temp, task.localPath);
      // The promotion succeeded, so this is the one moment the book file is known to be at
      // `task.localPath`. Only a book **file** is recorded: a cover that arrived without its
      // book is not a book the shelf can open, and marking it local would offer a reader a
      // file that is not there.
      if (task.kind === TransferKind.BOOK_DOWNLOAD) {
        this.downloadedDestinations.set(task.bookId, task.localPath);
      }
      // One last report at the true final size, so a transfer whose last threshold-crossing
      // chunk arrived just before the end still lands on a complete reading.
      if (onBytes !== undefined && lastReceived > 0) {
        onBytes(lastReceived, lastReceived);
      }
      return true;
    } catch (err) {
      // A failed transfer may have left a partial file. `move` is the only thing
      // that promotes a download, so anything still at a temporary path is debris.
      await this.removeTempFor(task, 'download');
      // Logged, with the reason. `false` is all the caller sees, and a sync that counted
      // 18 failures without one line saying why is a report no one can act on: the cause
      // is spread across an HTTP status, a disk error and a timeout, and they need
      // different fixes. `kind` is included when the error carries one, so a 404 (the
      // server has no such file — the scan and the plan disagree) reads differently from
      // a timeout or a permission refusal.
      const detail: string = err instanceof Error ? err.message : String(err);
      const kind: string = err instanceof InkBoatError ? ` [${err.kind}]` : '';
      const status: string = err instanceof InkBoatError && err.status > 0
        ? ` (HTTP ${err.status})`
        : '';
      hilog.warn(DOMAIN, TAG,
        'transfer failed: %{public}s book %{public}s remote %{public}s -> local %{public}s: %{public}s%{public}s%{public}s',
        transferKindName(task.kind), shortIdOf(task.bookId), remotePath, task.localPath,
        kind, status, detail);
      return false;
    }
  }

  /** Deterministic temporary path for a transfer, so a failure can clean it up. */
  private tempPathFor(task: TransferTask, prefix: string): string {
    return this.storage.tempPath(`${prefix}-${task.kind}-${sanitizeForPath(task.bookId)}`);
  }

  /** Remove a transfer's temporary file, ignoring every failure. */
  private async removeTempFor(task: TransferTask, prefix: string): Promise<void> {
    try {
      await this.storage.remove(this.tempPathFor(task, prefix));
    } catch (err) {
      // Best effort: a leftover temporary file wastes space but breaks nothing, and
      // the next transfer overwrites the same deterministic path anyway.
    }
  }

  /**
   * Apply the plan's status side effects.
   *
   * `markLocal` and `markRemote` are mutually exclusive per book by construction,
   * so applying them in either order is safe. Orphans are deliberately untouched:
   * marking a book with no file anywhere as `remote` is what makes a client offer
   * a download that must 404.
   *
   * The third step is the one the plan cannot express. `plan.markLocal` is decided from the
   * state gathered **before** the transfers, so the book this pass downloaded has
   * `local.fileExists === false` there and never enters that list; the same snapshot keeps it
   * out of `markRemote`, because the file does exist on the server. Without a step keyed on
   * what actually landed, a successful download changes nothing in the row — the file is on
   * the device, `sync_status` still says `remote`, and the shelf refuses to open it with
   * 「这本书的文件还在服务器上，请先同步下载」. It runs **last**, so a transfer that really
   * happened has the final word on the row it wrote to. Both engines call this method
   * (`V1FilePhase.runFilePhaseBody`, `SyncEngine`'s binary phase), so the rule cannot differ
   * between the two protocols.
   */
  async applyStatusChanges(plan: BinarySyncPlan): Promise<void> {
    for (const bookId of plan.markLocal) {
      try {
        await this.books.markLocalIfPresent(bookId);
      } catch (err) {
        // A status flag is cosmetic; a failure here must not abort the pass. Logged
        // because a book left with a stale status is re-checked on every sync, so a
        // persistent failure shows up as repeated work rather than as an error.
        hilog.warn(DOMAIN, TAG, 'markLocal failed for %{public}s: %{public}s',
          bookId, String(err));
      }
    }
    for (const bookId of plan.markRemote) {
      try {
        await this.books.markRemoteOnly(bookId);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'markRemote failed for %{public}s: %{public}s',
          bookId, String(err));
      }
    }
    await this.markDownloadedBooksLocal();
  }

  /**
   * Mark every book whose **book file** this pass downloaded as present locally.
   *
   * Membership is written by `runTask` only after the promotion succeeded, so a transfer that
   * failed, threw, or was never attempted is absent and its row keeps `sync_status = 'remote'`
   * — the file is not there and the shelf must go on offering the download.
   *
   * `file_hash` is passed empty, which the repository stores as NULL: a downloaded file is
   * byte-identical to the server's, so there is no local hash to record here, and nothing in
   * this app decides availability from `file_hash` — `gatherState` asks the filesystem
   * (`FileStorage.info`) and the shelf reads `sync_status`. Re-deriving a path from the row is
   * deliberately not done: a row whose `file_path` was empty (a peer's upload strips it,
   * `bookToSyncRecordForUpload`) has no path to re-derive from, and it is exactly that row
   * this download just filled in.
   */
  private async markDownloadedBooksLocal(): Promise<void> {
    const ids: string[] = [];
    this.downloadedDestinations.forEach((_destination: string, bookId: string): void => {
      ids.push(bookId);
    });
    for (const bookId of ids) {
      const relative: string = this.downloadedBookPath(bookId);
      if (relative.length === 0) {
        // Only reachable for a destination outside the app's files directory, which no path
        // builder here produces. Logged rather than skipped in silence: a book left `remote`
        // with a file on disk is indistinguishable from a failed download, and the log line
        // is the only thing that tells the two apart.
        hilog.warn(DOMAIN, TAG,
          'downloaded book %{public}s has no sandbox-relative destination; sync_status left unchanged',
          shortIdOf(bookId));
        continue;
      }
      try {
        await this.books.markAvailableLocally(bookId, relative, '');
        hilog.info(DOMAIN, TAG, 'book %{public}s downloaded to %{public}s; recorded local',
          shortIdOf(bookId), relative);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'markAvailableLocally failed for %{public}s: %{public}s',
          shortIdOf(bookId), String(err));
      }
    }
    // Cleared, so a later pass cannot re-mark a download from an earlier one. The row must
    // describe a file this pass put on the device; a stale entry would claim a book is here
    // whose file has since been removed, and the shelf would then open nothing.
    this.downloadedDestinations.clear();
  }

  /** Where a successful download of this pass wrote, as `file_path` stores it, or `''`. */
  private downloadedBookPath(bookId: string): string {
    const destination: string = this.downloadedDestinations.get(bookId) ?? '';
    return destination.length === 0 ? '' : this.storageRelativePath(destination);
  }

  /**
   * The sandbox-relative form of a path a transfer wrote.
   *
   * `file_path` holds `books/{id}.{ext}` — what `canonicalBookFilePath` and
   * `FileStorage.bookPath` produce and what the metadata merge reads back — so the app's own
   * files directory is stripped rather than stored a second time. An absolute path outside
   * that directory cannot be expressed relative to it and yields `''`, which the caller
   * treats as "no usable destination" rather than writing a path this device alone can read.
   */
  private storageRelativePath(written: string): string {
    const prefix: string = `${this.storage.root()}/`;
    if (written.startsWith(prefix)) {
      return written.substring(prefix.length);
    }
    // A path that is already relative is kept as it is; a `books/...` value must not be
    // turned into `.../files/books/...` by prefixing it again.
    return written.startsWith('/') ? '' : written;
  }

  /**
   * Build the manifest from the state observed this pass, corrected for transfers.
   *
   * A book that was just downloaded has a local file and a size the pre-transfer
   * snapshot did not record, so the remote size is used for it instead. Getting
   * this wrong publishes `fileSize: 0` for every downloaded book, and the next
   * device to trust the manifest would then treat every size comparison as a
   * change.
   *
   * **`filePath` is written only for a file the server is known to hold.** That is
   * `remote.fileExists` — the manifest entry said so, or the folder listing did — or an
   * upload this pass confirmed (`this.uploaded`). `local.fileExists` alone is *not*
   * evidence and must never be: this pass may have planned an upload that then failed, and
   * a manifest that claims the file is present makes ReadAny — which trusts this document
   * — show a book that the server does not have, permanently, because the next pass reads
   * the manifest, believes the file is there, and never retries the upload.
   *
   * That was the defect here: the entry was emitted whenever `remote.fileExists ||
   * local.fileExists`, so any local-only book whose upload failed was advertised. A book
   * with only a cover already on the server still gets an entry (with `coverPath` and no
   * `filePath`), which is what keeps the covers it does have discoverable.
   */
  buildManifest(state: BookBinaryInput[], now: number): RemoteFileManifest {
    const manifest: RemoteFileManifest = emptyManifest();
    manifest.generatedAt = now;

    for (const input of state) {
      const wasTransferred: boolean = this.transferred.has(input.bookId);

      const fileOnServer: boolean = input.remote.fileExists || this.uploaded.has(input.bookId);
      const coverOnServer: boolean = (input.remote.coverExists || this.uploaded.has(input.bookId))
        && input.coverExt.length > 0;
      if (!fileOnServer && !coverOnServer) {
        continue;
      }

      const folderName: string = buildBookFolderName(input.bookId, input.title);
      const stem: string = sanitizeStem(input.title);
      const entry: ManifestEntry = emptyManifestEntry(folderName);

      if (fileOnServer) {
        entry.filePath = `${REMOTE_BOOKS_ROOT}/${folderName}/${stem}.${input.format}`;
        // Prefer whichever side actually knows the size. After a download only the
        // remote side does.
        if (input.local.fileExists && !wasTransferred) {
          entry.fileSize = input.local.fileSize;
        } else {
          entry.fileSize = input.remote.fileSize > 0 ? input.remote.fileSize : input.local.fileSize;
        }
      }

      if (coverOnServer) {
        entry.coverPath = `${REMOTE_BOOKS_ROOT}/${folderName}/${stem}.${input.coverExt}`;
        if (input.local.coverExists && !wasTransferred) {
          entry.coverSize = input.local.coverSize;
        } else {
          entry.coverSize = input.remote.coverSize > 0
            ? input.remote.coverSize
            : input.local.coverSize;
        }
        entry.coverHash = input.local.coverHash.length > 0
          ? input.local.coverHash
          : input.remote.coverHash;
        entry.coverSourcePath = input.coverUrl;
      }
      entry.updatedAt = now;
      manifest.books.set(input.bookId, entry);
    }

    return manifest;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private findBook(bookId: string): Book | undefined {
    for (const book of this.lastBooks) {
      if (book.id === bookId) {
        return book;
      }
    }
    return undefined;
  }

  /**
   * Turn a stored relative path into an absolute one.
   *
   * Legacy rows carry either a bare relative path, a `file://` URI, or an already
   * absolute sandbox path depending on which client wrote them, so all three are
   * handled rather than assuming the current format.
   */
  private absoluteOf(relativeOrAbsolute: string, fallback?: string): string {
    if (relativeOrAbsolute.startsWith('file://')) {
      return relativeOrAbsolute.substring('file://'.length);
    }
    if (relativeOrAbsolute.startsWith('/')) {
      return relativeOrAbsolute;
    }
    if (relativeOrAbsolute.length === 0) {
      return fallback ?? '';
    }
    return `${this.storage.root()}/${relativeOrAbsolute}`;
  }
}

/** Title sanitizer for a manifest stem, matching the shared naming rule. */
function sanitizeStem(title: string): string {
  const cleaned: string = title
    .replace(/[/\\:*?"<>|]/g, '_')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned.length > 0 ? cleaned.substring(0, 64) : '未命名';
}

/**
 * Make an identifier safe to use as a single path segment.
 *
 * Book ids are generated UUIDs and are already safe, but a row that arrived from a
 * peer carries whatever that peer wrote, and a `/` in it would silently turn a
 * temporary file name into a nested path that `tempPath` does not create.
 */
function sanitizeForPath(value: string): string {
  const cleaned: string = value.replace(/[/\\:*?"<>|\s]/g, '_');
  return cleaned.length > 0 ? cleaned.substring(0, 64) : 'unknown';
}

/** True when the manifest describes every book passed in. */
function manifestCoversEveryBook(
  manifest: RemoteFileManifest,
  books: BinaryBookInput[],
): boolean {
  for (const book of books) {
    if (!manifest.books.has(book.bookId)) {
      return false;
    }
  }
  return true;
}

/** Remote state derived from a manifest entry. */
function remoteStateFromEntry(entry: ManifestEntry, coverExt: string): RemoteBinaryState {
  const state: RemoteBinaryState = unknownRemoteState();
  state.fileExists = entry.filePath.length > 0;
  state.fileSize = entry.fileSize;
  state.coverExists = entry.coverPath.length > 0;
  state.coverSize = entry.coverSize;
  state.coverHash = entry.coverHash;
  state.coverSourcePath = entry.coverSourcePath;
  // A manifest entry with no cover path but a known cover extension means the
  // cover is not described; treating it as absent lets the plan upload it.
  if (coverExt.length === 0) {
    state.coverExists = false;
  }
  return state;
}

/**
 * A manifest that is present and is not JSON.
 *
 * Same distinction as the sync index and the per-book files, and the same consequence if
 * it is missed: the manifest is rewritten from this pass's view at the end of the binary
 * phase, so a document that merely could not be parsed must not be replaced by a narrower
 * one. The first characters are quoted because the usual cause is a proxy or file host
 * answering with an HTML error page.
 */
function unparseableManifestMessage(excerpt: string): string {
  const head: string = excerpt.length > 0 ? excerpt : '(空)';
  return `远端 ${REMOTE_FILE_MANIFEST} 存在但不是可解析的 JSON（开头：${head}）。`
    + '为避免用它覆盖掉同伴记录的文件清单，本次没有重写它，也没有传输书籍文件。';
}

/** Extension of a logical remote path. */
function extensionOfRemote(path: string): string {
  const name: string = path.substring(path.lastIndexOf('/') + 1);
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/**
 * A transfer kind as a word, for a log line.
 *
 * Spelled out rather than interpolated from the enum, because the enum's values are
 * stable identifiers meant for code and a report that says `book_download` where the
 * user's own progress line says "下载" is a translation step too many. The fallback
 * names the value it did not recognise rather than printing `undefined`.
 */
function transferKindName(kind: TransferKind): string {
  if (kind === TransferKind.BOOK_UPLOAD) {
    return 'upload book';
  }
  if (kind === TransferKind.BOOK_DOWNLOAD) {
    return 'download book';
  }
  if (kind === TransferKind.COVER_UPLOAD) {
    return 'upload cover';
  }
  if (kind === TransferKind.COVER_DOWNLOAD) {
    return 'download cover';
  }
  return `transfer(${kind})`;
}

/** First eight characters of an id, for a log line. */
function shortIdOf(id: string): string {
  return id.length > 8 ? id.substring(0, 8) : id;
}
