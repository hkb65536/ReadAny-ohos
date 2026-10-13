/**
 * The `books`-only local path rules of the v1 per-device protocol.
 *
 * Extracted from `SyncV1.ets` so that the v1 **file phase** (`V1FilePhase.ets`) can use the
 * same canonical-path functions the metadata merge uses without importing the engine — and
 * therefore without the engine importing the file phase as a *value*. The engine holds the
 * file phase as a type (`V1FileRunner`), and ArkTS resolves a cycle the moment either side
 * needs the other at runtime: `V1FilePhase` needs `canonicalBookFilePath` at runtime, so if
 * that function lived in `SyncV1.ets` the two modules would import each other for real.
 *
 * A shared leaf module is the standard way out, and it happens to be the right shape here:
 * these three functions are pure string transformations with no dependency on the engine,
 * the transport or the database, and they are the *only* part of the v1 protocol the file
 * layer is entitled to know — where a book's file and cover live inside the sandbox.
 *
 * The rules are ported from ReadAny v1.3.6 `packages/core/src/sync/local-book-paths.ts` and
 * must not be re-derived: the path a row stores has to mean the same thing on every device,
 * and two implementations of "canonical" that disagree is the whole failure mode.
 */

const DEFAULT_BOOK_EXTENSION: string = 'epub';
const DEFAULT_COVER_EXTENSION: string = 'jpg';

/**
 * Source formats that **no client stores under their own extension**.
 *
 * ReadAny converts these to EPUB at import and writes the result as
 * `books/{id}.epub` while recording the *source* format in the `format` column
 * (`packages/app/src/stores/library-store.ts:404-405` sets `format` to `'txt'`/`'umd'`,
 * `:439` and `:465` hard-code `books/${bookId}.epub`). Its own
 * `canonicalBookFilePath` call then resolves the extension from `file_path`, not from
 * `format` (`packages/core/src/sync/sync-files.ts:414-416`).
 *
 * The consequence is the trap this constant exists to close: a row may legitimately say
 * `format = 'txt'` while the only file it can ever have is `books/{id}.epub`. Deriving
 * `.txt` from that `format` points at a file that does not exist, and 15 such rows were
 * observed on a device with zero `.txt` files on disk.
 */
const CONVERTED_SOURCE_FORMATS: string[] = ['txt', 'umd'];

/** Lower-cased extension of a path name, without the dot, or an empty string. */
function pathExtension(path: string): string {
  const clean: string = path.split('?')[0].split('#')[0].split('\\').join('/');
  const leaf: string = clean.substring(clean.lastIndexOf('/') + 1);
  const dot: number = leaf.lastIndexOf('.');
  return dot >= 0 ? leaf.substring(dot + 1).toLowerCase() : '';
}

/** A format string reduced to something usable as a file extension. */
function normalizedExtension(value: string): string {
  const trimmed: string = value.trim().toLowerCase();
  const withoutDot: string = trimmed.startsWith('.') ? trimmed.substring(1) : trimmed;
  return /^[a-z0-9]+$/.test(withoutDot) ? withoutDot : '';
}

/** True for a source format that is always stored converted. */
export function isConvertedSourceFormat(format: string): boolean {
  return CONVERTED_SOURCE_FORMATS.includes(normalizedExtension(format));
}

/**
 * The extension a book's **stored file** actually has.
 *
 * The single rule every path builder in this app must use, in priority order:
 *
 *  1. the extension of the real `file_path`, when it has one — the file's own name is
 *     evidence and nothing else here is;
 *  2. `epub`, when `format` is a format every client stores converted
 *     (`CONVERTED_SOURCE_FORMATS`) — such a book has no file under its source extension
 *     anywhere, so `.txt`/`.umd` would name a file that cannot exist;
 *  3. the `format` string, when it looks like an extension — the last resort, for a row
 *     whose path is unknown *and* whose format is not one of the converted ones;
 *  4. `epub`.
 *
 * Note that step 1 wins even when it disagrees with `format`: a `.txt` really on disk
 * under a `format = 'txt'` row is that file, and reinterpreting it as EPUB would point
 * the reader at a name that does not exist. The rule only ever overrides `format` when
 * the path yields nothing at all.
 */
export function resolveBookExtension(
  filePath: Object | null | undefined,
  format: Object | null | undefined,
): string {
  const path: string = typeof filePath === 'string' ? filePath : '';
  const fromPath: string = pathExtension(path);
  if (fromPath.length > 0) {
    return fromPath;
  }
  const fmt: string = typeof format === 'string' ? format : '';
  if (isConvertedSourceFormat(fmt)) {
    return DEFAULT_BOOK_EXTENSION;
  }
  return normalizedExtension(fmt) || DEFAULT_BOOK_EXTENSION;
}

/**
 * The canonical local path of a book file: `books/{id}.{ext}`.
 *
 * Ported from `canonicalBookFilePath` (v1.3.6
 * `packages/core/src/sync/local-book-paths.ts`). A peer's `file_path` points
 * inside *that device's* sandbox, so it is discarded in favour of the path this
 * device would have used — which is the only way a book pulled from a desktop
 * can be opened here. Only the **extension** survives, and it is chosen by
 * `resolveBookExtension` so no caller can compose this path from `format` alone.
 */
export function canonicalBookFilePath(
  bookId: Object | null | undefined,
  filePath: Object | null | undefined,
  format: Object | null | undefined,
): string {
  const id: string = bookId === undefined || bookId === null ? '' : String(bookId).trim();
  return id.length > 0 ? `books/${id}.${resolveBookExtension(filePath, format)}` : '';
}

/** The canonical local path of a book file with a **known** stored extension. */
export function bookFilePathForExtension(bookId: string, extension: string): string {
  const id: string = bookId.trim();
  if (id.length === 0) {
    return '';
  }
  return `books/${id}.${normalizedExtension(extension) || DEFAULT_BOOK_EXTENSION}`;
}

/**
 * The canonical local cover path, or `null` when there is no cover.
 *
 * Ported from `canonicalBookCoverPath`. Three cases:
 *  - a remote `http(s)` URL is kept — the only kind of cover reference that is
 *    already valid on every device;
 *  - a relative path is reduced to `covers/{leaf}`, keeping an existing
 *    `covers/` prefix;
 *  - an absolute path (including any other scheme) becomes `covers/{id}.{ext}`,
 *    because an absolute path is meaningless on this device.
 */
export function canonicalBookCoverPath(
  bookId: Object | null | undefined,
  coverUrl: Object | null | undefined,
): string | null {
  if (coverUrl === undefined || coverUrl === null || coverUrl === '') {
    return null;
  }
  if (typeof coverUrl !== 'string') {
    return null;
  }
  const raw: string = coverUrl.trim();
  if (raw.length === 0) {
    return null;
  }
  if (/^https?:\/\//i.test(raw)) {
    return raw;
  }
  const normalized: string = raw.split('\\').join('/');
  const isAbsolute: boolean = normalized.startsWith('/')
    || /^[A-Za-z]:\//.test(normalized)
    || /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(normalized);
  if (!isAbsolute) {
    const leaf: string = normalized.substring(normalized.lastIndexOf('/') + 1);
    if (leaf.length === 0) {
      return null;
    }
    return normalized.startsWith('covers/') ? normalized : `covers/${leaf}`;
  }
  const id: string = bookId === undefined || bookId === null ? '' : String(bookId).trim();
  if (id.length === 0) {
    return normalized;
  }
  const ext: string = pathExtension(normalized) || DEFAULT_COVER_EXTENSION;
  return `covers/${id}.${ext}`;
}

/** True for a cover the user supplied: `covers/{id}-custom-*`. */
export function isCustomCoverPath(bookId: string, value: Object | null | undefined): boolean {
  return typeof value === 'string' && value.startsWith(`covers/${bookId}-custom-`);
}

/** True for the cover extracted from the book itself: `covers/{id}.{ext}`. */
export function isCanonicalCoverPath(bookId: string, value: Object | null | undefined): boolean {
  return typeof value === 'string' && value.startsWith(`covers/${bookId}.`);
}
