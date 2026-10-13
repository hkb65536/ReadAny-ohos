/**
 * Remote naming rules for the per-book layout.
 *
 * Ported verbatim from ReadAny `packages/core/src/sync/sync-naming.ts`. The
 * sanitizer and folder template decide where a book lands on the server, so a
 * single differing character means the two clients create separate folders for
 * the same book instead of sharing one.
 *
 *     /readany/data/books/{sanitized-title}-{bookId}/{sanitized-title}.{ext}
 *
 * The folder name is `{sanitized-title}-{uuid}` and the book file and cover
 * share the sanitized title as their stem, distinguished by extension.
 */

import { isStrictUuidV4 } from 'core';
import { BOOK_EXTENSIONS, COVER_EXTENSIONS, REMOTE_BOOKS_ROOT } from './SyncConstants';

const FALLBACK_TITLE: string = '未命名';
const MAX_TITLE_LEN: number = 64;

/** Characters that are unsafe in a WebDAV path segment or a local filename. */
const UNSAFE_CHARS: RegExp = /[/\\:*?"<>|]/g;
/**
 * Control characters, built from code points so no literal control byte ends up
 * in this source file.
 */
const CONTROL_CHARS: RegExp =
  new RegExp(`[${String.fromCharCode(0)}-${String.fromCharCode(31)}${String.fromCharCode(127)}]`, 'g');
const WHITESPACE_RUN: RegExp = /\s+/g;

/**
 * Strip filesystem / WebDAV-unsafe characters, collapse whitespace, cap the
 * length and fall back to a placeholder for empty input.
 */
export function sanitizeBookTitleForFs(title: string | null | undefined): string {
  if (title === null || title === undefined || title.length === 0) {
    return FALLBACK_TITLE;
  }
  const cleaned: string = title
    .replace(UNSAFE_CHARS, '_')
    .replace(CONTROL_CHARS, '')
    .replace(WHITESPACE_RUN, ' ')
    .trim();
  if (cleaned.length === 0) {
    return FALLBACK_TITLE;
  }
  return cleaned.substring(0, MAX_TITLE_LEN);
}

/** Folder name segment (no leading path): `{title}-{id}`. */
export function buildBookFolderName(bookId: string, title: string | null | undefined): string {
  return `${sanitizeBookTitleForFs(title)}-${bookId}`;
}

/** Full remote directory for a book. */
export function buildBookRemoteDir(bookId: string, title: string | null | undefined): string {
  return `${REMOTE_BOOKS_ROOT}/${buildBookFolderName(bookId, title)}`;
}

/**
 * Book file path: the stem is the sanitized title, the suffix the format.
 *
 * `ext` is appended exactly as given — a leading dot is NOT stripped, because
 * the reference implementation does not strip it either. Normalizing it here
 * would produce `三体..epub` and break path compatibility with the other clients.
 */
export function buildBookRemoteFile(
  bookId: string,
  title: string | null | undefined,
  ext: string,
): string {
  return `${buildBookRemoteDir(bookId, title)}/${sanitizeBookTitleForFs(title)}.${ext}`;
}

/** Cover path: same folder and stem as the book file. Same `ext` rule applies. */
export function buildBookRemoteCover(
  bookId: string,
  title: string | null | undefined,
  ext: string,
): string {
  return `${buildBookRemoteDir(bookId, title)}/${sanitizeBookTitleForFs(title)}.${ext}`;
}

/**
 * Extract `bookId` from a folder name `{title}-{uuid}`.
 *
 * Returns an empty string when the trailing 36 characters are not a UUID-shaped
 * string, which is how the caller tells a book folder apart from an unrelated
 * directory.
 *
 * The **strict** v4 check is used, matching the reference implementation's regex
 * (`/^[0-9a-f]{8}-…-4…-[89ab]…$/`) rather than the looser shape-only form. The reason
 * is interoperability in one direction: the shape check accepts folders the reference
 * would reject, so this client could count a directory as a book folder that no other
 * client recognises. The strict check rejects nothing this client creates — its own
 * generator emits version-4 ids — so it only ever tightens agreement.
 */
export function parseBookFolderName(folderName: string): string {
  if (folderName.length < 37) {
    return '';
  }
  const candidateId: string = folderName.substring(folderName.length - 36);
  if (!isStrictUuidV4(candidateId)) {
    return '';
  }
  if (folderName.charAt(folderName.length - 37) !== '-') {
    return '';
  }
  return candidateId;
}

/** Lower-cased extension of a file name, or empty when there is none. */
export function extensionOf(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return fileName.substring(dot + 1).toLowerCase();
}

/** Heuristic: a file inside a book folder is a cover if its extension is an image format. */
export function isCoverFileName(fileName: string): boolean {
  const ext: string = extensionOf(fileName);
  if (ext.length === 0) {
    return false;
  }
  return COVER_EXTENSIONS.includes(ext);
}

/** Heuristic: a file inside a book folder is a book if its extension is a known book format. */
export function isBookFileName(fileName: string): boolean {
  const ext: string = extensionOf(fileName);
  if (ext.length === 0) {
    return false;
  }
  return BOOK_EXTENSIONS.includes(ext);
}
