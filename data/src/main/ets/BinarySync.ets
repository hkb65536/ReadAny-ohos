/**
 * Binary file sync: book files, covers and the remote file manifest.
 *
 * Ported from ReadAny `packages/core/src/sync/sync-files.ts`.
 *
 * Decisions and execution are separated on purpose. `planBinarySync` is a pure
 * function over the local and remote state, so the rule that decides whether a
 * file is uploaded or downloaded can be reasoned about — and cross-checked
 * against the reference — without a server.
 *
 * Remote layout, from the shared naming module so it cannot drift from what the
 * other clients write:
 *
 *     /readany/data/books/{sanitized-title}-{bookId}/{sanitized-title}.{ext}
 *
 * The book file and its cover share a stem and are distinguished by extension.
 */

import {
  buildBookFolderName,
  buildBookRemoteCover,
  buildBookRemoteFile,
  FILE_SCHEMA_VERSION,
  REMOTE_FILE_MANIFEST,
  sanitizeBookTitleForFs,
} from 'sync';

/** One book's entry in `file-manifest.json`. */
export interface ManifestEntry {
  folderName: string;
  filePath: string;
  coverPath: string;
  fileSize: number;
  coverSize: number;
  coverHash: string;
  coverSourcePath: string;
  updatedAt: number;
}

/** `/readany/data/file-manifest.json`. */
export interface RemoteFileManifest {
  version: number;
  generatedAt: number;
  books: Map<string, ManifestEntry>;
}

export function emptyManifest(): RemoteFileManifest {
  return { version: FILE_SCHEMA_VERSION, generatedAt: 0, books: new Map<string, ManifestEntry>() };
}

export function emptyManifestEntry(folderName: string): ManifestEntry {
  return {
    folderName: folderName,
    filePath: '',
    coverPath: '',
    fileSize: 0,
    coverSize: 0,
    coverHash: '',
    coverSourcePath: '',
    updatedAt: 0,
  };
}

/** What is known about one book's binaries on the remote. */
export interface RemoteBinaryState {
  /** The book file exists on the server. */
  fileExists: boolean;
  fileSize: number;
  /** The cover exists on the server. */
  coverExists: boolean;
  coverSize: number;
  coverHash: string;
  /**
   * The `cover_url` of the device that uploaded the current remote cover.
   *
   * Needed to detect a replaced *custom* cover: the bytes differ, but the local
   * hash may be unavailable, so the recorded source path is the only signal.
   */
  coverSourcePath: string;
}

export function unknownRemoteState(): RemoteBinaryState {
  return {
    fileExists: false,
    fileSize: 0,
    coverExists: false,
    coverSize: 0,
    coverHash: '',
    coverSourcePath: '',
  };
}

/** What is known about one book's binaries on this device. */
export interface LocalBinaryState {
  fileExists: boolean;
  fileSize: number;
  coverExists: boolean;
  coverSize: number;
  coverHash: string;
}

export enum TransferKind {
  BOOK_UPLOAD = 'book-upload',
  BOOK_DOWNLOAD = 'book-download',
  COVER_UPLOAD = 'cover-upload',
  COVER_DOWNLOAD = 'cover-download',
}

/** A single transfer to perform. */
export interface TransferTask {
  bookId: string;
  kind: TransferKind;
  /** Logical protocol path, before `remoteRoot` substitution. */
  remotePath: string;
  /** Absolute path inside the app sandbox. */
  localPath: string;
  /** Size hint for progress; 0 when unknown. */
  size: number;
  /**
   * The book's title, for the live progress line.
   *
   * Optional so a hand-built task in a test or a probe still compiles: the planner, which
   * is the only production caller, always fills it in. A progress line that named a
   * truncated UUID instead would tell the user nothing about which book is moving, which
   * is the whole reason the line exists.
   */
  title?: string;
}

/** The full set of transfers for one pass. */
export interface BinarySyncPlan {
  uploads: TransferTask[];
  downloads: TransferTask[];
  /** Books whose file is present locally and whose row should say so. */
  markLocal: string[];
  /** Books that are metadata-only on this device. */
  markRemote: string[];
  /**
   * Books with no file locally *or* remotely.
   *
   * Their status is deliberately left untouched. Flipping them to `remote` is the
   * bug that makes a client offer a download for a file that exists nowhere,
   * which then 404s; leaving the row visibly broken is more honest.
   */
  orphans: string[];
}

/** Result counters for one pass. */
export interface BinarySyncCounts {
  uploaded: number;
  downloaded: number;
  failed: number;
}

export function emptyBinaryCounts(): BinarySyncCounts {
  return { uploaded: 0, downloaded: 0, failed: 0 };
}

/** Input for one book. */
export interface BookBinaryInput {
  bookId: string;
  title: string;
  /** Book format, used as the file extension. */
  format: string;
  /** Local `cover_url`, empty when the book has no cover. */
  coverUrl: string;
  /** Extension of the local cover file, empty when there is none. */
  coverExt: string;
  localFilePath: string;
  localCoverPath: string;
  local: LocalBinaryState;
  remote: RemoteBinaryState;
  /**
   * `{sanitized-title}-{bookId}` — the folder this book's files belong in.
   *
   * Filled in by the gatherer rather than derived from `title` here, because the two can
   * disagree: a title is mutable locally while the manifest entry for it was written by a
   * peer, and the folder is part of the remote path a manifest records. Carrying the value
   * the gatherer actually used is what keeps a `MKCOL` and the `PUT` that follows it aimed
   * at the same directory.
   */
  folderName: string;
  /**
   * `books/{id}.{ext}` — the sandbox-**relative** path, which is the form the `books` row
   * stores in `file_path`. Kept alongside the absolute `localFilePath` so a download can
   * record the row without re-deriving the canonical path (and possibly deriving a
   * different one).
   */
  relativeFilePath: string;
}

/** Options controlling what a pass is allowed to do. */
export interface BinarySyncOptions {
  /** Upload files even when the server already has one. */
  forceUploadAll: boolean;
  /** Download files even when a local copy exists. */
  forceDownloadAll: boolean;
  /** Download remote book files at all; false means metadata only. */
  downloadRemoteBooks: boolean;
  /** Skip every upload, for the "restore from server" path. */
  disableUploads: boolean;
}

export function defaultBinaryOptions(): BinarySyncOptions {
  return {
    forceUploadAll: false,
    forceDownloadAll: false,
    // `false`, matching the reference implementation. Book binaries are large and a
    // normal pass must stay cheap: a library pulled over cellular because the user
    // tapped "同步" is not something they asked for. Covers still download when
    // missing, so the shelf looks right either way, and an explicit full download is
    // what moves the book files.
    //
    // This was `true`, which made every normal pass fetch the whole library.
    downloadRemoteBooks: false,
    disableUploads: false,
  };
}

// ---------------------------------------------------------------------------
// The v1 file phase's contract
// ---------------------------------------------------------------------------
//
// These live here, in the shared leaf module, rather than in either of the two modules
// that need them. `SyncV1.ets` (the engine) and `V1FilePhase.ets` (the phase) must not
// import each other: the engine reaches the phase through `V1FileRunner` and the phase
// reaches the canonical paths through `../V1BookPaths`, and if the contract sat in either
// one the two files would need each other at runtime. Put it in the module both already
// depend on and the cycle cannot exist.
//
// The interface is deliberately one method wide. It exposes no delete, no MOVE, no rename
// and no directory listing, so v1.3.6's `cleanupRemoteOrphans` — which needs a listing and
// a `DELETE` — cannot be expressed against the handle the engine holds.

/**
 * What the v1 file phase moved, and whether it could rewrite the manifest.
 *
 * `failed` counts a transfer that reported failure, not an aborted phase: one book that
 * will not move must not stop the others, exactly as in the reference's `runFileTasks`.
 */
export interface V1FileCounts {
  uploaded: number;
  downloaded: number;
  failed: number;
  /**
   * True when the manifest write was abandoned because the remote document could not be
   * read. Surfaced separately from `failed` so the summary can name the real cause instead
   * of reporting a failed transfer that did not happen.
   */
  manifestRefused: boolean;
  /** The refusal text, empty unless `manifestRefused`. */
  manifestError: string;
  /**
   * Why the whole phase stopped, empty when it ran to the end.
   *
   * Set only when something outside a single transfer went wrong — the remote `books` root
   * could not be listed, the database read failed. Reported rather than thrown: the
   * metadata half of the pass has already succeeded, and losing that result because a file
   * would not move would misreport the pass.
   */
  error: string;
  /**
   * The first distinct reason a transfer failed, empty when none did.
   *
   * `failed` is a count, and a count is not actionable: the observable defect was a pass
   * that reported "失败 18" and nothing anywhere saying whether every one of those was the
   * same missing file, the same 403, or the same timeout. The reasons a transfer can fail
   * need different fixes, and 18 identical failures are a different problem from 18
   * different ones. Recorded from the transfer's own exception (or from the check that
   * returned "not found"), never inferred from the count.
   */
  firstFailure: string;
}

export function emptyV1FileCounts(): V1FileCounts {
  return {
    uploaded: 0,
    downloaded: 0,
    failed: 0,
    manifestRefused: false,
    manifestError: '',
    error: '',
    firstFailure: '',
  };
}

/** One progress line from the v1 file phase, in the engine's own vocabulary. */
export type V1FileProgressFn = (message: string, completed: number, total: number) => void;

/**
 * The v1 file phase, as the v1 **engine** is allowed to see it.
 *
 * Implemented explicitly by `V1FilePhase` because ArkTS has no structural typing
 * (`arkts-no-structural-typing`, `docs/arkts-constraints.md` §2.0): a class that merely
 * *looks* right is not assignable.
 */
export interface V1FileRunner {
  /** Run one file phase and report what moved. Never throws for one failed file. */
  runFilePhase(options: BinarySyncOptions, onProgress?: V1FileProgressFn): Promise<V1FileCounts>;
}

/** True for a cover the user supplied, which lives next to the book as `{id}-custom-*`. */
export function isCustomCoverFileName(bookId: string, fileName: string): boolean {
  return fileName.startsWith(`${bookId}-custom-`);
}

/**
 * Decide the transfers for one pass.
 *
 * Rules, ported from the reference:
 *
 * Book file
 *   upload    local file exists AND (forcing OR the server has none)
 *   download  remote file exists AND (forcing OR (downloading is on AND no local copy))
 *
 * Cover
 *   upload    local cover exists AND (forcing OR the server has none OR it changed)
 *   download  remote cover exists AND (forcing OR no local copy OR (uploads are off
 *             AND it changed))
 *
 * The receive-only clause on the cover matters: that path cannot push its own
 * cover, so if it did not also pull a changed one it would keep a cover that the
 * server has already replaced.
 *
 * A book file is never compared by content — only by presence and, on download,
 * by size. Hashing a multi-hundred-megabyte book on every pass would cost more
 * than the upload it is meant to avoid. Covers are small enough to hash, and the
 * hash is one of three signals; the recorded source path is checked first because
 * it catches a replaced custom cover even when no hash is available.
 */
export function planBinarySync(
  inputs: BookBinaryInput[],
  options: BinarySyncOptions,
): BinarySyncPlan {
  const plan: BinarySyncPlan = {
    uploads: [],
    downloads: [],
    markLocal: [],
    markRemote: [],
    orphans: [],
  };

  for (const input of inputs) {
    const bookId: string = input.bookId;
    const local: LocalBinaryState = input.local;
    const remote: RemoteBinaryState = input.remote;

    const bookRemotePath: string = buildBookRemoteFile(bookId, input.title, input.format);

    // ---- book file ------------------------------------------------------
    if (local.fileExists) {
      // The file is here, so availability is `local` regardless of what the row said.
      plan.markLocal.push(bookId);
      if (!options.disableUploads && (options.forceUploadAll || !remote.fileExists)) {
        plan.uploads.push({
          bookId: bookId,
          kind: TransferKind.BOOK_UPLOAD,
          remotePath: bookRemotePath,
          localPath: input.localFilePath,
          size: local.fileSize,
          title: input.title,
        });
      }
    }

    if (remote.fileExists
      && (options.forceDownloadAll || (options.downloadRemoteBooks && !local.fileExists))) {
      plan.downloads.push({
        bookId: bookId,
        kind: TransferKind.BOOK_DOWNLOAD,
        remotePath: bookRemotePath,
        localPath: input.localFilePath,
        size: remote.fileSize,
        title: input.title,
      });
    } else if (!local.fileExists && remote.fileExists) {
      plan.markRemote.push(bookId);
    } else if (!local.fileExists && !remote.fileExists) {
      plan.orphans.push(bookId);
    }

    // ---- cover ----------------------------------------------------------
    const hasLocalCover: boolean = input.localCoverPath.length > 0;
    if (input.coverUrl.length === 0 && !hasLocalCover) {
      continue;
    }

    const coverFileName: string = fileNameOf(input.coverUrl);
    const isCustom: boolean = isCustomCoverFileName(bookId, coverFileName);
    const ext: string = input.coverExt.length > 0 ? input.coverExt : 'jpg';
    const coverRemotePath: string = buildBookRemoteCover(bookId, input.title, ext);

    const coverSourceChanged: boolean = isCustom
      && remote.coverSourcePath.length > 0
      && remote.coverSourcePath !== input.coverUrl;
    const coverHashChanged: boolean = local.coverHash.length > 0
      && remote.coverHash.length > 0
      && local.coverHash !== remote.coverHash;
    const sizeDiffers: boolean = local.coverSize > 0
      && remote.coverSize > 0
      && local.coverSize !== remote.coverSize;
    // A custom cover with no recorded provenance on either side cannot be trusted
    // to be current; re-uploading it is cheap and settles the question.
    const customProvenanceMissing: boolean = isCustom
      && (local.coverSize <= 0 || remote.coverSize <= 0 || remote.coverSourcePath.length === 0);

    const coverChanged: boolean = remote.coverExists
      && local.coverExists
      && (coverSourceChanged || coverHashChanged || sizeDiffers || customProvenanceMissing);

    if (!options.disableUploads
      && local.coverExists
      && (options.forceUploadAll || !remote.coverExists || coverChanged)) {
      plan.uploads.push({
        bookId: bookId,
        kind: TransferKind.COVER_UPLOAD,
        remotePath: coverRemotePath,
        localPath: input.localCoverPath,
        size: local.coverSize,
        title: input.title,
      });
    }

    if (remote.coverExists
      && (options.forceDownloadAll || !local.coverExists
        || (options.disableUploads && coverChanged))) {
      plan.downloads.push({
        bookId: bookId,
        kind: TransferKind.COVER_DOWNLOAD,
        remotePath: coverRemotePath,
        localPath: input.localCoverPath,
        size: remote.coverSize,
        title: input.title,
      });
    }
  }

  return plan;
}

/** Remote folder name for a book, from the shared naming rule. */
export function remoteFolderName(bookId: string, title: string): string {
  return buildBookFolderName(bookId, title);
}

/** Remote stem for a book's file and cover. */
export function remoteStem(title: string): string {
  return sanitizeBookTitleForFs(title);
}

/** The manifest path, as a logical protocol path. */
export function manifestPath(): string {
  return REMOTE_FILE_MANIFEST;
}

/** Last path segment. */
function fileNameOf(value: string): string {
  const trimmed: string = value.replace(/\/+$/, '');
  const parts: string[] = trimmed.split('/');
  return parts.length > 0 ? parts[parts.length - 1] : '';
}

/**
 * Serialize the manifest for upload.
 *
 * `books` is a map on the wire, so it is built by assignment rather than embedded
 * as a literal — ArkTS will not accept a literal as the value of
 * `Record<string, Object>`.
 */
export function manifestToWire(manifest: RemoteFileManifest, now: number): Record<string, Object> {
  const books: Record<string, Object> = {};
  manifest.books.forEach((entry: ManifestEntry, bookId: string): void => {
    const wire: Record<string, Object> = {};
    wire['folderName'] = entry.folderName;
    // Optional fields are omitted when empty, matching the reference writer, so a
    // manifest written by this client is byte-comparable with one written there.
    if (entry.filePath.length > 0) {
      wire['filePath'] = entry.filePath;
    }
    if (entry.coverPath.length > 0) {
      wire['coverPath'] = entry.coverPath;
    }
    if (entry.fileSize > 0) {
      wire['fileSize'] = entry.fileSize;
    }
    if (entry.coverSize > 0) {
      wire['coverSize'] = entry.coverSize;
    }
    if (entry.coverHash.length > 0) {
      wire['coverHash'] = entry.coverHash;
    }
    if (entry.coverSourcePath.length > 0) {
      wire['coverSourcePath'] = entry.coverSourcePath;
    }
    if (entry.updatedAt > 0) {
      wire['updatedAt'] = entry.updatedAt;
    }
    books[bookId] = wire;
  });

  const out: Record<string, Object> = {};
  out['version'] = FILE_SCHEMA_VERSION;
  out['generatedAt'] = now;
  out['books'] = books;
  return out;
}

/** Parse a manifest document. An unrecognised version yields an empty manifest. */
export function manifestFromWire(record: Record<string, Object> | undefined): RemoteFileManifest {
  if (record === undefined) {
    return emptyManifest();
  }
  if (record['version'] !== FILE_SCHEMA_VERSION) {
    return emptyManifest();
  }
  const booksWire: Object | undefined = record['books'];
  if (booksWire === undefined || booksWire === null || typeof booksWire !== 'object') {
    return emptyManifest();
  }

  const books: Map<string, ManifestEntry> = new Map<string, ManifestEntry>();
  const table: Record<string, Object> = booksWire as Record<string, Object>;
  for (const bookId of Object.keys(table)) {
    const raw: Object = table[bookId];
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      continue;
    }
    const entry: Record<string, Object> = raw as Record<string, Object>;
    books.set(bookId, {
      folderName: stringOf(entry, 'folderName'),
      filePath: stringOf(entry, 'filePath'),
      coverPath: stringOf(entry, 'coverPath'),
      fileSize: numberIn(entry, 'fileSize'),
      coverSize: numberIn(entry, 'coverSize'),
      coverHash: stringOf(entry, 'coverHash'),
      coverSourcePath: stringOf(entry, 'coverSourcePath'),
      updatedAt: numberIn(entry, 'updatedAt'),
    });
  }
  return {
    version: FILE_SCHEMA_VERSION,
    generatedAt: numberIn(record, 'generatedAt'),
    books: books,
  };
}

/**
 * True when the manifest has an entry for every book we know about.
 *
 * A manifest missing entries is worse than no manifest: each absent entry reads
 * as "the server has nothing", so the client would re-upload files it already
 * has. When this returns false the caller falls back to listing remote folders.
 */
export function manifestCoversAll(manifest: RemoteFileManifest, bookIds: string[]): boolean {
  for (const id of bookIds) {
    if (!manifest.books.has(id)) {
      return false;
    }
  }
  return true;
}

function stringOf(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key];
  if (value === undefined || value === null) {
    return '';
  }
  return typeof value === 'string' ? value : String(value);
}

function numberIn(record: Record<string, Object>, key: string): number {
  const value: Object | undefined = record[key];
  if (typeof value === 'number' && !Number.isNaN(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}
