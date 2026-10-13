/**
 * Domain mappers.
 *
 * One function per entity, used for both directions of truth: reading local SQL
 * rows and applying remote JSON records. Sharing the mapper is deliberate — if
 * the pull path and the UI path disagreed about a default, a synced book would
 * render differently from a locally imported one.
 *
 * Ported from ReadAny `packages/core/src/db/{book,bookmark,highlight,note}-queries.ts`.
 */

import type { HighlightColor, RecordReader } from 'core';
import { JsonRecordReader } from 'core';
import type { Book, BookFormat, BookGroup, Bookmark, Highlight, Note, SyncStatus } from './Types';

/**
 * Parse a JSON column that holds an array, mirroring ReadAny's `parseJSON`.
 *
 * A malformed value yields an empty array rather than throwing: this runs while
 * mapping a row that a peer may have written, and one bad `tags` column must not
 * make a whole book unreadable.
 */
export function parseJsonArray(value: string): string[] {
  if (value.length === 0) {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(value) as Object;
    if (!Array.isArray(parsed)) {
      return [];
    }
    const out: string[] = [];
    for (const item of parsed as Object[]) {
      out.push(typeof item === 'string' ? item : JSON.stringify(item));
    }
    return out;
  } catch (err) {
    return [];
  }
}

/** Column order used by every `INSERT`/upsert against `books`. */
export const BOOK_COLUMNS: string[] = [
  'id', 'file_path', 'format', 'title', 'author', 'publisher', 'language', 'isbn',
  'description', 'cover_url', 'publish_date', 'rating', 'reviews', 'subjects',
  'total_pages', 'total_chapters', 'group_id', 'added_at', 'last_opened_at',
  'deleted_at', 'progress', 'current_cfi', 'current_spine', 'current_dom_pos',
  'is_vectorized', 'vectorize_progress',
  'tags', 'updated_at', 'file_hash', 'sync_status', 'sync_version', 'last_modified_by',
];

export const HIGHLIGHT_COLUMNS: string[] = [
  'id', 'book_id', 'cfi', 'text', 'color', 'note', 'chapter_title',
  'created_at', 'updated_at', 'sync_version', 'last_modified_by',
];

export const NOTE_COLUMNS: string[] = [
  'id', 'book_id', 'highlight_id', 'cfi', 'title', 'content', 'chapter_title',
  'tags', 'created_at', 'updated_at', 'sync_version', 'last_modified_by',
];

export const BOOKMARK_COLUMNS: string[] = [
  'id', 'book_id', 'cfi', 'label', 'chapter_title', 'created_at', 'updated_at',
  'sync_version', 'last_modified_by',
];

const FORMATS: string[] = ['epub', 'pdf', 'mobi', 'azw', 'azw3', 'cbz', 'fb2', 'fbz', 'txt', 'umd'];
const HIGHLIGHT_COLOR_NAMES: string[] =
  ['red', 'yellow', 'green', 'blue', 'pink', 'purple', 'violet'];

/** Coerce a persisted format string into the union, defaulting to `epub`. */
function toFormat(value: string): BookFormat {
  const lower: string = value.toLowerCase();
  return FORMATS.includes(lower) ? (lower as BookFormat) : 'epub';
}

/** Coerce a persisted colour into the union, defaulting to `yellow`. */
function toHighlightColor(value: string): HighlightColor {
  const lower: string = value.toLowerCase();
  return HIGHLIGHT_COLOR_NAMES.includes(lower) ? (lower as HighlightColor) : 'yellow';
}

function toSyncStatus(value: string, hasFile: boolean): SyncStatus {
  if (value === 'remote' || value === 'downloading') {
    return value;
  }
  // An empty status means a row that predates the column or arrived from a peer
  // before we knew about the file; `local` only if the file path looks usable.
  return hasFile ? 'local' : 'remote';
}

/** Map a `books` record to the domain object. */
export function toBook(reader: RecordReader): Book {
  const filePath: string = reader.str('file_path');
  return {
    id: reader.str('id'),
    filePath: filePath,
    format: toFormat(reader.str('format')),
    title: reader.str('title'),
    author: reader.str('author'),
    publisher: reader.str('publisher'),
    language: reader.str('language'),
    isbn: reader.str('isbn'),
    description: reader.str('description'),
    coverUrl: reader.str('cover_url'),
    publishDate: reader.str('publish_date'),
    rating: reader.num('rating', 0),
    reviews: reader.str('reviews'),
    subjects: reader.str('subjects'),
    totalPages: reader.num('total_pages', 0),
    totalChapters: reader.num('total_chapters', 0),
    groupId: reader.str('group_id'),
    addedAt: reader.num('added_at', 0),
    lastOpenedAt: reader.num('last_opened_at', 0),
    updatedAt: reader.num('updated_at', 0),
    deletedAt: reader.num('deleted_at', 0),
    progress: reader.num('progress', 0),
    currentCfi: reader.str('current_cfi'),
    currentSpine: reader.num('current_spine', 0),
    currentDomPos: reader.str('current_dom_pos'),
    tags: parseJsonArray(reader.str('tags')),
    fileHash: reader.str('file_hash'),
    syncStatus: toSyncStatus(reader.str('sync_status'), filePath.length > 0),
  };
}

/** Bind values for a `books` row, in `BOOK_COLUMNS` order. */
export function bookValues(book: Book, syncVersion: number, deviceId: string): (string | number | null)[] {
  return [
    book.id, book.filePath, book.format, book.title, book.author,
    emptyToNull(book.publisher), emptyToNull(book.language), emptyToNull(book.isbn),
    emptyToNull(book.description), emptyToNull(book.coverUrl), emptyToNull(book.publishDate),
    book.rating, emptyToNull(book.reviews), emptyToNull(book.subjects),
    book.totalPages, book.totalChapters, emptyToNull(book.groupId),
    book.addedAt, book.lastOpenedAt > 0 ? book.lastOpenedAt : null,
    book.deletedAt > 0 ? book.deletedAt : null,
    book.progress, emptyToNull(book.currentCfi),
    book.currentSpine, emptyToNull(book.currentDomPos),
    // `is_vectorized` and `vectorize_progress` belong to the RAG feature, which
    // this client does not implement. They are written as 0 so the columns stay
    // consistent for a peer that does read them back.
    0, 0,
    JSON.stringify(book.tags), book.updatedAt,
    emptyToNull(book.fileHash), book.syncStatus, syncVersion, deviceId,
  ];
}

/** Map a `bookmarks` record to the domain object. */
export function toBookmark(reader: RecordReader): Bookmark {
  return {
    id: reader.str('id'),
    bookId: reader.str('book_id'),
    cfi: reader.str('cfi'),
    label: reader.str('label'),
    chapterTitle: reader.str('chapter_title'),
    createdAt: reader.num('created_at', 0),
    updatedAt: reader.num('updated_at', 0),
  };
}

export function bookmarkValues(
  bookmark: Bookmark,
  syncVersion: number,
  deviceId: string,
): (string | number | null)[] {
  return [
    bookmark.id, bookmark.bookId, bookmark.cfi,
    emptyToNull(bookmark.label), emptyToNull(bookmark.chapterTitle),
    bookmark.createdAt, bookmark.updatedAt, syncVersion, deviceId,
  ];
}

/** Map a `highlights` record to the domain object. */
export function toHighlight(reader: RecordReader): Highlight {
  return {
    id: reader.str('id'),
    bookId: reader.str('book_id'),
    cfi: reader.str('cfi'),
    text: reader.str('text'),
    color: toHighlightColor(reader.str('color')),
    note: reader.str('note'),
    chapterTitle: reader.str('chapter_title'),
    createdAt: reader.num('created_at', 0),
    updatedAt: reader.num('updated_at', 0),
  };
}

export function highlightValues(
  highlight: Highlight,
  syncVersion: number,
  deviceId: string,
): (string | number | null)[] {
  return [
    highlight.id, highlight.bookId, highlight.cfi, highlight.text, highlight.color,
    emptyToNull(highlight.note), emptyToNull(highlight.chapterTitle),
    highlight.createdAt, highlight.updatedAt, syncVersion, deviceId,
  ];
}

/** Map a `notes` record to the domain object. */
export function toNote(reader: RecordReader): Note {
  return {
    id: reader.str('id'),
    bookId: reader.str('book_id'),
    highlightId: reader.str('highlight_id'),
    cfi: reader.str('cfi'),
    title: reader.str('title'),
    content: reader.str('content'),
    chapterTitle: reader.str('chapter_title'),
    tags: parseJsonArray(reader.str('tags')),
    createdAt: reader.num('created_at', 0),
    updatedAt: reader.num('updated_at', 0),
  };
}

export function noteValues(note: Note, syncVersion: number, deviceId: string): (string | number | null)[] {
  return [
    note.id, note.bookId, emptyToNull(note.highlightId), emptyToNull(note.cfi),
    note.title, note.content, emptyToNull(note.chapterTitle),
    JSON.stringify(note.tags), note.createdAt, note.updatedAt, syncVersion, deviceId,
  ];
}

/** SQLite stores absent strings as NULL, not `''`. */
function emptyToNull(value: string): string | null {
  return value.length > 0 ? value : null;
}

/**
 * A book as it appears in a sync file.
 *
 * Keys are the SQLite column names, because that is what peers parse — there is
 * no camelCase translation on the wire. Written out field by field rather than
 * zipped from `BOOK_COLUMNS` so that a column added to the table fails to compile
 * here until the wire format is updated deliberately, instead of silently
 * appearing in (or vanishing from) what other devices receive.
 *
 * ## Four columns deliberately do not travel
 *
 * `is_vectorized` and `vectorize_progress` are **stripped by ReadAny itself**, for the
 * same reason this client strips them: the RAG chunks and their embeddings live in a
 * *local* database (`readany_local.db`), so "is this book vectorized" is a per-device
 * fact rather than shared state. Sending this device's `0` would tell the desktop it had
 * never indexed a book it had indexed, and the desktop would re-vectorise the whole
 * library. `simple-sync.ts:46-54` is the reference's own `excludeColumns` list, and these
 * are exactly its two entries.
 *
 * `sync_version` and `last_modified_by` are stripped for a different but related reason.
 * ReadAny does carry them (they are not in its `excludeColumns`), because on the
 * reference they hold *real* values: a monotonic per-table watermark and the id of the
 * device that made the change. This client's domain object carries neither, so the only
 * thing this mapper could put on the wire is a fabricated `0` and `''` — which would
 * overwrite the peer's attribution and push its `sync_version` watermark backwards. The
 * columns are therefore **omitted**, and omission is the safe direction: ReadAny's
 * `upsertRecord` builds its `INSERT ... ON CONFLICT DO UPDATE SET` from the keys actually
 * present in the record, so an omitted column keeps whatever the peer already had
 * (`simple-sync.ts:412-444`).
 *
 * The v1 per-device path is untouched by this: it reads raw rows with `SELECT *` and
 * applies the reference's own `excludeColumns`, so it carries this device's real
 * `sync_version` / `last_modified_by` values (`SyncV1.collectTableChanges`).
 */
export function bookToSyncRecord(book: Book): Record<string, Object> {
  const record: Record<string, Object> = {};
  record['id'] = book.id;
  record['file_path'] = book.filePath;
  record['format'] = book.format;
  record['title'] = book.title;
  record['author'] = book.author;
  record['publisher'] = book.publisher;
  record['language'] = book.language;
  record['isbn'] = book.isbn;
  record['description'] = book.description;
  record['cover_url'] = book.coverUrl;
  record['publish_date'] = book.publishDate;
  record['rating'] = book.rating;
  record['reviews'] = book.reviews;
  record['subjects'] = book.subjects;
  record['total_pages'] = book.totalPages;
  record['total_chapters'] = book.totalChapters;
  record['group_id'] = book.groupId;
  record['added_at'] = book.addedAt;
  record['last_opened_at'] = book.lastOpenedAt;
  record['deleted_at'] = book.deletedAt;
  record['progress'] = book.progress;
  record['current_cfi'] = book.currentCfi;
  record['current_spine'] = book.currentSpine;
  record['current_dom_pos'] = book.currentDomPos;
  record['tags'] = JSON.stringify(book.tags);
  record['updated_at'] = book.updatedAt;
  record['file_hash'] = book.fileHash;
  record['sync_status'] = book.syncStatus;
  return record;
}

export function highlightToSyncRecord(highlight: Highlight): Record<string, Object> {
  const record: Record<string, Object> = {};
  record['id'] = highlight.id;
  record['book_id'] = highlight.bookId;
  record['cfi'] = highlight.cfi;
  record['text'] = highlight.text;
  record['color'] = highlight.color;
  record['note'] = highlight.note;
  record['chapter_title'] = highlight.chapterTitle;
  record['created_at'] = highlight.createdAt;
  record['updated_at'] = highlight.updatedAt;
  return record;
}

export function noteToSyncRecord(note: Note): Record<string, Object> {
  const record: Record<string, Object> = {};
  record['id'] = note.id;
  record['book_id'] = note.bookId;
  record['highlight_id'] = note.highlightId;
  record['cfi'] = note.cfi;
  record['title'] = note.title;
  record['content'] = note.content;
  record['chapter_title'] = note.chapterTitle;
  record['tags'] = JSON.stringify(note.tags);
  record['created_at'] = note.createdAt;
  record['updated_at'] = note.updatedAt;
  return record;
}

export function bookmarkToSyncRecord(bookmark: Bookmark): Record<string, Object> {
  const record: Record<string, Object> = {};
  record['id'] = bookmark.id;
  record['book_id'] = bookmark.bookId;
  record['cfi'] = bookmark.cfi;
  record['label'] = bookmark.label;
  record['chapter_title'] = bookmark.chapterTitle;
  record['created_at'] = bookmark.createdAt;
  record['updated_at'] = bookmark.updatedAt;
  return record;
}

/**
 * A book row for upload.
 *
 * A peer's `file_path` points inside *that* device's sandbox and is meaningless
 * here, so the local path is stripped and the row is marked remote: whoever
 * receives it has the metadata but not the file, which is exactly the truth.
 */
export function bookToSyncRecordForUpload(book: Book): Record<string, Object> {
  const record: Record<string, Object> = bookToSyncRecord(book);
  record['file_path'] = '';
  record['sync_status'] = 'remote';
  return record;
}

/**
 * Map a `book_groups` row to the domain object.
 *
 * `sort_order` defaults to 0 rather than being required: a group created by an older
 * client may not carry it, and ordering by zero is a sane fallback — the group simply
 * sorts first.
 */
export function toBookGroup(reader: RecordReader): BookGroup {
  return {
    id: reader.str('id'),
    name: reader.str('name'),
    sortOrder: reader.num('sort_order', 0),
    createdAt: reader.num('created_at', 0),
    updatedAt: reader.num('updated_at', 0),
    syncVersion: reader.num('sync_version', 0),
    lastModifiedBy: reader.str('last_modified_by'),
  };
}

/** The `book_groups` wire row. Column names are the reference client's. */
export function bookGroupToSyncRecord(group: BookGroup): Record<string, Object> {
  const record: Record<string, Object> = {};
  record['id'] = group.id;
  record['name'] = group.name;
  record['sort_order'] = group.sortOrder;
  record['created_at'] = group.createdAt;
  record['updated_at'] = group.updatedAt;
  record['sync_version'] = group.syncVersion;
  record['last_modified_by'] = group.lastModifiedBy;
  return record;
}

/**
 * Read a wire row back into a `BookGroup`.
 *
 * Written by hand rather than through `RecordReader`, because wire rows are loose
 * objects rather than database rows. It exists so `applyRemote` does not have to know
 * the column names, keeping them in one place with their writer.
 */
export function bookGroupFromWire(row: Record<string, Object>): BookGroup {
  const reader: RecordReader = new JsonRecordReader(row);
  return toBookGroup(reader);
}
