/**
 * Domain types for the four supported features.
 *
 * Field names are camelCase and mirror ReadAny's `types/book.ts` and
 * `types/annotation.ts`. The database uses snake_case columns; conversion happens
 * in the repositories, exactly as the reference clients do it.
 *
 * The annotation types explicitly `extend PositionedAnnotation` rather than
 * merely having the same fields: ArkTS does not implement structural typing, so a
 * nominal `extends` is required before a shared position comparator accepts them.
 * `HighlightColor`, `HIGHLIGHT_COLOR_HEX` and `HIGHLIGHT_COLORS` come from `core`
 * for the same reason — one definition shared with the renderer.
 */

import type { HighlightColor, PositionedAnnotation } from 'core';

export type { HighlightColor };
export { HIGHLIGHT_COLOR_HEX, HIGHLIGHT_COLORS } from 'core';

/** Book formats this client can open. */
export type BookFormat =
  | 'epub'
  | 'pdf'
  | 'mobi'
  | 'azw'
  | 'azw3'
  | 'cbz'
  | 'fb2'
  | 'fbz'
  | 'txt'
  | 'umd';

/** Whether the book file itself is present locally. */
export type SyncStatus = 'local' | 'remote' | 'downloading';

export interface Book {
  id: string;
  /** Path inside the app sandbox, e.g. `books/{id}.epub`. */
  filePath: string;
  format: BookFormat;
  title: string;
  author: string;
  publisher: string;
  language: string;
  isbn: string;
  description: string;
  coverUrl: string;
  publishDate: string;
  rating: number;
  reviews: string;
  subjects: string;
  totalPages: number;
  totalChapters: number;
  groupId: string;
  addedAt: number;
  lastOpenedAt: number;
  updatedAt: number;
  /** Non-zero when the row is a tombstone. */
  deletedAt: number;
  /** Reading progress, 0-1. */
  progress: number;
  /**
   * EPUB CFI, or a `page:{N}` pseudo-CFI for PDF.
   *
   * A ReadAny client writes a page-precise CFI here. This client reads it to decide
   * which chapter to open (`spineOrdinalFromCfi`) and writes a **spine-level** CFI
   * back (`spineCfiFor`) so the desktop lands in the same chapter. The exact page is
   * not expressible in this direction; a position this client can restore exactly is
   * `currentSpine` / `currentDomPos`.
   */
  currentCfi: string;
  /**
   * Reader Kit spine index, this client's own position coordinate.
   *
   * `0` is also the column default, so a zero here does not by itself mean the book
   * has been read: `hasSyncedPosition` is the test for "the position columns hold a
   * position".
   */
  currentSpine: number;
  /** Reader Kit DOM position inside the spine item. */
  currentDomPos: string;
  tags: string[];
  fileHash: string;
  syncStatus: SyncStatus;
}

export interface Bookmark extends PositionedAnnotation {
  id: string;
  bookId: string;
  label: string;
  chapterTitle: string;
  updatedAt: number;
}

export interface Highlight extends PositionedAnnotation {
  id: string;
  bookId: string;
  /** EPUB CFI *range*. */
  text: string;
  color: HighlightColor;
  note: string;
  chapterTitle: string;
  updatedAt: number;
}

/**
 * A free-form note.
 *
 * `cfi` is optional in the database but non-optional here: an empty string means
 * "not anchored". That keeps `PositionedAnnotation` satisfiable without an
 * optional field, which ArkTS comparisons handle badly.
 */
export interface Note extends PositionedAnnotation {
  id: string;
  bookId: string;
  /** Set when the note was created from a highlight. */
  highlightId: string;
  title: string;
  /** Markdown. */
  content: string;
  chapterTitle: string;
  tags: string[];
  updatedAt: number;
}

/** A book plus its annotation counts, for the library grid. */
export interface BookWithCounts {
  book: Book;
  bookmarkCount: number;
  highlightCount: number;
  noteCount: number;
}

/**
 * A shelf group.
 *
 * `group_id` on `Book` is only a reference into this table — the name and ordering
 * live here, so a client without this table can see that a book belongs to a group
 * but cannot say what the group is called.
 */
export interface BookGroup {
  id: string;
  name: string;
  sortOrder: number;
  createdAt: number;
  updatedAt: number;
  /** Sync bookkeeping, carried so a peer can resolve conflicts. */
  syncVersion: number;
  lastModifiedBy: string;
}

/** Columns of `book_groups`, in DDL order, for positional writes. */
export const BOOK_GROUP_COLUMNS: string[] = [
  'id', 'name', 'sort_order', 'created_at', 'updated_at', 'sync_version',
  'last_modified_by',
];
