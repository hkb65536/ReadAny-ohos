/**
 * Sync protocol constants.
 *
 * These paths and file names are a wire contract shared with the ReadAny
 * desktop and mobile clients. Changing any literal here silently breaks
 * interoperability — a client with a different root simply cannot see the
 * other's data. Ported from ReadAny `packages/core/src/sync/sync-types.ts`
 * and the per-book layout constants in `per-book-sync.ts`.
 */

/** Remote root, as used in logical paths before `remoteRoot` substitution. */
export const REMOTE_ROOT: string = '/readany';
/** Default remote root; users may point this at a sub-directory of their DAV share. */
export const DEFAULT_REMOTE_ROOT: string = 'readany';

/** Directory holding the per-device / per-book metadata files. */
export const REMOTE_SYNC: string = '/readany/sync';
/** `/readany/sync/index.json` — the book/thread membership index (schemaVersion 2). */
export const REMOTE_SYNC_INDEX: string = '/readany/sync/index.json';
/** `/readany/sync/books/{bookId}.json` — one file per book. */
export const REMOTE_SYNC_BOOKS: string = '/readany/sync/books';
/** `/readany/data` — binaries (book files and covers). */
export const REMOTE_DATA: string = '/readany/data';
/** Canonical per-book binary folder root. */
export const REMOTE_BOOKS_ROOT: string = '/readany/data/books';
/** Legacy flat layout, still created and read during the transition window. */
export const REMOTE_FILES: string = '/readany/data/file';
/** Legacy flat cover layout. */
export const REMOTE_COVERS: string = '/readany/data/cover';
/** `/readany/data/file-manifest.json` — binary index. */
export const REMOTE_FILE_MANIFEST: string = '/readany/data/file-manifest.json';

/**
 * Profile files: one uniform single-table file per table.
 *
 * `book_groups` is the only member this client syncs. It is the one profile table
 * with the full sync field set (`updated_at`, `sync_version`, `last_modified_by`),
 * which means it merges by exactly the same rule as a book row — reuse, not a new
 * mechanism.
 *
 * `tags` and `book_tags` are deliberately excluded. They carry **no** `updated_at`,
 * and `book_tags` is a bare join table, so "last writer wins per row on the timestamp
 * column" has nothing to compare. Guessing a merge rule for them would risk damaging
 * data that this client does not otherwise touch; leaving them alone means they simply
 * do not travel through this client, which is a gap rather than a corruption.
 *
 * `skills` belongs to the AI feature set and is out of scope.
 */
export const REMOTE_PROFILE: string = '/readany/sync/profile';

/** Profile tables this client reads and writes. */
export const PROFILE_TABLES: string[] = ['book_groups'];

/** The one profile table that carries the full sync field set. */
export const PROFILE_BOOK_GROUPS: string = 'book_groups';

/** Index file `schemaVersion` for the per-book layout. */
export const INDEX_SCHEMA_VERSION: number = 2;
/** Per-book / profile / chat file `schemaVersion`. */
export const FILE_SCHEMA_VERSION: number = 1;

/** Tables whose rows travel inside a per-book file. */
export const ANNOTATION_TABLES: string[] = ['highlights', 'notes', 'bookmarks'];

/** Columns stripped from a `books` row before it is written to the remote. */
export const BOOK_LOCAL_EXCLUDED_COLUMNS: string[] = ['is_vectorized', 'vectorize_progress'];

/** Timestamp column per synced table. */
export function timestampColumnFor(table: string): string {
  return table === 'messages' ? 'created_at' : 'updated_at';
}

// ---------------------------------------------------------------------------
// Tombstone sanity bound
// ---------------------------------------------------------------------------

/**
 * How far into the future a remote deletion timestamp may claim to be.
 *
 * A tombstone is a *destructive* instruction: applying one deletes the local row
 * and writes a sticky local tombstone, so a corrupt or hostile remote file that
 * carries an absurd `deletedAt` (the audited case is `books[id].d = 9e15`, which
 * is year ~287396) destroys the row and its annotations and cannot be undone by a
 * re-pull, because the index's `a` marker is not lowered and the pull is skipped.
 * Nothing on the old path compared a tombstone against the wall clock, and
 * `numberCell` happily accepts any finite number *and* numeric strings, so
 * `9e15` and `"9999999999999999"` both flowed straight into the cascade delete.
 *
 * One day is deliberate:
 *
 *  - It is far wider than any real skew between a single user's own devices. A
 *    device whose clock is off by more than 24 h is misconfigured, not merely
 *    skewed; NTP-corrected phones and desktops are within seconds of each other,
 *    and even a manually-set clock is normally wrong by minutes or a time zone
 *    (≤ 14 h end-to-end), which still fits.
 *  - It is many orders of magnitude below the fabricated values this bound
 *    exists to reject. `9e15` ms and `"9999999999999999"` are ~2.8e8 years in the
 *    future; Date.now() + 86_400_000 is ~1.75e12 today, so the two ranges cannot
 *    be confused by any rounding, unit slip or parse artefact.
 *  - Failing closed here is cheap and failing open is not: a tombstone beyond the
 *    bound is *ignored* for this pass — the row is kept, the remote tombstone
 *    stays in the remote file, and nothing is overwritten — whereas applying a
 *    bogus one is unrecoverable data loss.
 *
 * Deliberately **not** keyed off a stored "last sync" time: a device that has
 * been offline for a year must still be able to delete something it deleted a
 * year ago, and that timestamp is in the *past*, so it passes this bound as
 * before. Only future-dated deletions are bounded.
 */
export const MAX_FUTURE_TOMBSTONE_SKEW_MS: number = 24 * 60 * 60 * 1000;

/** Extensions treated as cover images inside a book folder. */
export const COVER_EXTENSIONS: string[] =
  ['jpg', 'jpeg', 'png', 'webp', 'avif', 'gif', 'bmp'];

/** Extensions treated as book files inside a book folder. */
export const BOOK_EXTENSIONS: string[] =
  ['epub', 'pdf', 'mobi', 'azw', 'azw3', 'cbz', 'cbr', 'fb2', 'txt', 'umd'];

/** Keychain / Asset Store key holding the WebDAV password. */
export const SYNC_SECRET_KEY_WEBDAV: string = 'sync_webdav_password';
/** Preferences key holding the non-secret WebDAV configuration. */
export const SYNC_CONFIG_KEY_WEBDAV: string = 'sync_webdav_config';

// ---------------------------------------------------------------------------
// Sync modes
// ---------------------------------------------------------------------------

/**
 * Which sync the user asked for.
 *
 * Ported from the reference implementation's `forceFullSync(direction)`, where
 * `direction` is `"upload" | "download"`. The distinction exists because a normal pass
 * is deliberately **cheap**: it moves metadata and covers but not book files.
 *
 * That is not an optimisation detail — it is why the three modes differ at all. A
 * normal pass on a phone should not pull a whole library over cellular, so book
 * binaries move only when asked for explicitly.
 */
export enum SyncMode {
  /** Metadata both ways, plus covers. Book binaries only when the peer lacks one. */
  NORMAL = 'normal',
  /** A normal pass that additionally re-sends every local book file. */
  FULL_UPLOAD = 'full-upload',
  /** Pull metadata and every book file; upload nothing. */
  FULL_DOWNLOAD = 'full-download',
}

/**
 * The flags a mode implies.
 *
 * One struct rather than the four booleans being derived separately at each call site,
 * because the combinations are what carry the meaning and a wrong pairing is silent.
 * `FULL_DOWNLOAD` is the one that must get all of them right at once: receive-only
 * metadata, force-apply, force-download, remote books enabled, uploads disabled.
 */
export interface SyncPolicy {
  /** Metadata: skip every write, so nothing local is pushed. */
  receiveOnly: boolean;
  /** Metadata: apply a remote record even when it looks already merged. */
  forceApply: boolean;
  /** Binaries: send every local book file, even if the server already has one. */
  forceUploadAll: boolean;
  /** Binaries: fetch every remote book file, even if a local copy exists. */
  forceDownloadAll: boolean;
  /**
   * Binaries: fetch remote book files at all.
   *
   * `false` for `NORMAL` and `FULL_UPLOAD`, matching the reference implementation's
   * default. Uploads still happen in those modes when the server lacks a file — this
   * flag gates *downloads* only, so a new local import still reaches the server.
   */
  downloadRemoteBooks: boolean;
  /** Binaries: skip every upload. */
  disableUploads: boolean;
}

/** The flags a mode implies. See `SyncPolicy` for why they travel together. */
export function policyForMode(mode: SyncMode): SyncPolicy {
  if (mode === SyncMode.FULL_DOWNLOAD) {
    return {
      receiveOnly: true,
      forceApply: true,
      forceUploadAll: false,
      forceDownloadAll: true,
      downloadRemoteBooks: true,
      disableUploads: true,
    };
  }
  if (mode === SyncMode.FULL_UPLOAD) {
    return {
      receiveOnly: false,
      forceApply: false,
      forceUploadAll: true,
      forceDownloadAll: false,
      downloadRemoteBooks: false,
      disableUploads: false,
    };
  }
  return {
    receiveOnly: false,
    forceApply: false,
    forceUploadAll: false,
    forceDownloadAll: false,
    downloadRemoteBooks: false,
    disableUploads: false,
  };
}

/** Human-readable label, used for progress text and result messages. */
export function labelForMode(mode: SyncMode): string {
  if (mode === SyncMode.FULL_UPLOAD) {
    return '全量上传';
  }
  if (mode === SyncMode.FULL_DOWNLOAD) {
    return '全量下载';
  }
  return '同步';
}
