/**
 * Book repository.
 *
 * Ported from ReadAny `packages/core/src/db/book-queries.ts`, narrowed to the
 * operations the four supported features need.
 */

import type { RecordReader } from 'core';
import { jsonReader, spineCfiFor } from 'core';
import { isPlausibleTombstone, localRecordState, shouldApplyRemoteRecord } from 'sync';
import type { Database } from './Database';
import type { Row } from './Rdb';
import { sqlReader } from './RecordReader';
import { BOOK_COLUMNS, bookValues, toBook } from './Records';
import type { Book } from './Types';

/** Library sort order, as offered in the UI. */
export enum BookSort {
  RECENTLY_OPENED = 'recentlyOpened',
  RECENTLY_ADDED = 'recentlyAdded',
  TITLE = 'title',
  AUTHOR = 'author',
  PROGRESS = 'progress',
}

export interface LibraryQuery {
  /** Substring match against title and author; empty means no filter. */
  search: string;
  sort: BookSort;
}

export function defaultLibraryQuery(): LibraryQuery {
  return { search: '', sort: BookSort.RECENTLY_OPENED };
}

/**
 * `ORDER BY` for each sort mode.
 *
 * `last_opened_at IS NULL` is placed first in the key so never-opened books fall
 * to the end of a "recently opened" list instead of sorting as timestamp zero
 * *before* everything, which is what SQLite's default NULL ordering would do.
 */
function orderByFor(sort: BookSort): string {
  switch (sort) {
    case BookSort.RECENTLY_ADDED:
      return 'b.added_at DESC';
    case BookSort.TITLE:
      return 'b.title COLLATE NOCASE ASC';
    case BookSort.AUTHOR:
      return 'b.author COLLATE NOCASE ASC, b.title COLLATE NOCASE ASC';
    case BookSort.PROGRESS:
      return 'b.progress DESC';
    case BookSort.RECENTLY_OPENED:
    default:
      return 'b.last_opened_at IS NULL, b.last_opened_at DESC, b.added_at DESC';
  }
}

interface BookMarker {
  bookId: string;
  maxTs: number;
}

export interface AnnotationCounts {
  bookmarks: number;
  highlights: number;
  notes: number;
}

export class Books {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /**
   * Books visible on the shelf.
   *
   * Soft-deleted rows are excluded: a book is only removed from the local table
   * by `deleteBook`, but a peer's deletion arrives as `deleted_at` on the row
   * itself, so filtering by it is what makes remote deletions disappear.
   */
  async list(query: LibraryQuery): Promise<Book[]> {
    const rdb = this.db.rdbHandle;
    const conditions: string[] = ['COALESCE(b.deleted_at, 0) = 0'];
    const args: (string | number | null)[] = [];

    if (query.search.length > 0) {
      conditions.push('(b.title LIKE ? OR b.author LIKE ?)');
      const pattern: string = `%${query.search}%`;
      args.push(pattern, pattern);
    }

    const sql: string =
      `SELECT b.* FROM books b WHERE ${conditions.join(' AND ')} ORDER BY ${orderByFor(query.sort)}`;
    return await rdb.select<Book>(sql, (row: Row): Book => toBook(sqlReader(row)), args);
  }

  async getById(id: string): Promise<Book | undefined> {
    const rows: Book[] = await this.db.rdbHandle.select<Book>(
      'SELECT * FROM books WHERE id = ?',
      (row: Row): Book => toBook(sqlReader(row)),
      [id],
    );
    return rows.length > 0 ? rows[0] : undefined;
  }

  /** Live books including soft-deleted ones; the sync engine needs both. */
  async listAll(): Promise<Book[]> {
    return await this.db.rdbHandle.select<Book>(
      'SELECT * FROM books',
      (row: Row): Book => toBook(sqlReader(row)),
    );
  }

  /** Number of live books, for an empty-state decision without loading the list. */
  async count(): Promise<number> {
    const value: number = Number(
      await this.db.rdbHandle.scalar('SELECT COUNT(*) FROM books WHERE COALESCE(deleted_at, 0) = 0'),
    );
    return Number.isNaN(value) ? 0 : value;
  }

  /**
   * Insert or replace a book written by this device.
   *
   * `updated_at` is bumped to `max(now, current + 1)` so two edits inside one
   * millisecond still order deterministically against a peer.
   */
  async upsert(book: Book): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('books');
    const updatedAt: number = await this.db.nextUpdatedAt('books', book.id);
    // ArkTS has no object spread (`arkts-no-spread`) and restricts `Object.assign`
    // (`arkts-limited-stdlib`), so the copy is explicit.
    const stored: Book = copyBook(book);
    stored.updatedAt = updatedAt;
    await this.writeRow(stored, syncVersion, deviceId);
  }

  /**
   * Persist reading position.
   *
   * Called on a throttle from the reader, so this touches only the position
   * columns rather than rewriting the whole row: a full-row write would race a
   * concurrent metadata pull and could resurrect stale fields.
   *
   * A spine-level CFI is written alongside, so that a ReadAny client lands in the
   * same chapter rather than at the start of the book: `epubcfi(/6/{2(n+1)})` is the
   * spine item this position is in, and the desktop resolves that form. It is
   * coarser than a desktop CFI on purpose — this client's coordinate is the spine
   * index, and a page inside the chapter is not something it can express.
   *
   * **`current_cfi` is only written when a CFI can actually be computed for this
   * position.** When it cannot, the column keeps whatever a peer put there:
   * overwriting a peer's CFI with an empty string would destroy information this
   * client cannot regenerate. That rule predates the write-back and is what the
   * `COALESCE` preserves.
   */
  async updateReadingPosition(
    id: string,
    progress: number,
    spineIndex: number,
    domPos: string,
  ): Promise<void> {
    const clamped: number = progress < 0 ? 0 : progress > 1 ? 1 : progress;
    // `''` means "no CFI is computable"; `null` binds as SQL NULL and the `COALESCE`
    // then keeps the peer's existing value instead of blanking it.
    const computedCfi: string = spineCfiFor(spineIndex);
    const cfi: string | null = computedCfi.length > 0 ? computedCfi : null;
    // The whole read-modify-write runs as one retried unit. `nextSyncVersion` and
    // `nextUpdatedAt` read a value and the UPDATE writes it back; retrying only the
    // UPDATE after a lock conflict would persist a version read before the
    // conflicting write landed, and the row would then lose its next merge.
    // Resolved **before** the transaction, deliberately. `getDeviceId` reads through
    // `getMeta` (a plain query) and writes only on its first call in a process, and
    // that write is itself a queued one. Doing it inside `writeTransaction` put a
    // queued write inside a queue slot — a promise waiting for itself. `Rdb.runWithRetry`
    // now runs nested writes inline so this can no longer deadlock, but the read has no
    // reason to be part of the read-modify-write and keeping it outside means the
    // transaction covers only the version/value read and the `UPDATE`.
    const deviceId: string = await this.db.getDeviceId();
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      const syncVersion: number = await this.db.nextSyncVersion('books');
      const updatedAt: number = await this.db.nextUpdatedAt('books', id);

      await this.db.rdbHandle.execute(
        `UPDATE books SET progress = ?, current_spine = ?, current_dom_pos = ?,
          current_cfi = COALESCE(?, current_cfi),
          last_opened_at = ?, updated_at = ?, sync_version = ?, last_modified_by = ?
         WHERE id = ?`,
        [clamped, spineIndex, domPos, cfi, Date.now(), updatedAt, syncVersion, deviceId, id],
      );
    });
  }

  /** Flush any book stuck in `downloading` after the app was killed mid-transfer. */
  async resetInterruptedDownloads(): Promise<void> {
    await this.db.rdbHandle.execute(
      "UPDATE books SET sync_status = 'remote' WHERE sync_status = 'downloading'",
    );
  }

  /** Mark a book as present locally (after a successful download or import). */
  async markAvailableLocally(id: string, filePath: string, fileHash: string): Promise<void> {
    await this.db.rdbHandle.execute(
      "UPDATE books SET sync_status = 'local', file_path = ?, file_hash = ? WHERE id = ?",
      [filePath, fileHash.length > 0 ? fileHash : null, id],
    );
  }

  /** Mark a book as metadata-only, with its file still only on the server. */
  async markRemoteOnly(id: string): Promise<void> {
    await this.db.rdbHandle.execute("UPDATE books SET sync_status = 'remote' WHERE id = ?", [id]);
  }

  /**
   * Mark a book as present locally, but only when the row does not already say so.
   *
   * The guard keeps this from writing on every sync for every book: the sync pass
   * calls it for each book whose file it saw, and rewriting an unchanged flag would
   * be a write per book per pass.
   */
  async markLocalIfPresent(id: string): Promise<void> {
    await this.db.rdbHandle.execute(
      "UPDATE books SET sync_status = 'local' WHERE id = ? AND sync_status <> 'local'",
      [id],
    );
  }

  /**
   * Take a book off the shelf but keep its notes, highlights and reading history.
   *
   * This is ReadAny's `deleteBook(id, { preserveData: true })`
   * (`packages/core/src/db/book-queries.ts:349-367`) and it is the mode that
   * reference's delete dialog selects **by default**: the checkbox
   * 「保留笔记和阅读统计」 is checked when the dialog opens
   * (`packages/app/src/components/home/BookCard.tsx:79`). The row is not removed;
   * it is stamped with `deleted_at`, which is what takes the book out of every
   * shelf query — `list()` and `count()` both filter `COALESCE(deleted_at, 0) = 0`.
   *
   * **`deleted_at` is the whole mechanism, and it is a synced column.** A peer that
   * pulls this row sees `deleted_at` set and applies it as an ordinary row
   * (`SyncV1.ets:1210`: "ReadAny represents a 'deleted but kept' book as an ordinary
   * row with `deleted_at` set"), so nothing new goes on the wire — no new field, no
   * new record shape, no change to `V1_SYNC_TABLES`.
   *
   * The counterpart on the reference's side is worth stating plainly, because it is
   * destructive in a way this method is not: once the desktop holds this row,
   * ReadAny's `cleanupRemoteOrphans` no longer counts the book as live, so the
   * *uploaded file* is deleted from the server. That is the reference's behaviour,
   * not this client's — this client never deletes a remote file, in either mode.
   *
   * `is_vectorized` / `vectorize_progress` are reset exactly as the reference does.
   * It also drops the book's chat threads and vector chunks there; this schema has
   * neither table (see `Schema.ets`), so there is nothing to drop.
   *
   * The version and timestamp are read and written as one serialized unit, for the
   * reason `updateReadingPosition` gives: a version read before a conflicting write
   * landed would lose this row its next merge.
   */
  async softDeleteBook(id: string): Promise<void> {
    const deletedAt: number = Date.now();
    // Resolved before the transaction. `getDeviceId` reads through `getMeta` and
    // writes only on its first call in a process, and that write is itself queued;
    // putting it inside `writeTransaction` is the nesting `Rdb.runWithRetry` had to
    // be taught to run inline. Keeping it outside means the transaction covers only
    // the version and timestamp read and the `UPDATE`.
    const deviceId: string = await this.db.getDeviceId();
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      const syncVersion: number = await this.db.nextSyncVersion('books');
      const updatedAt: number = await this.db.nextUpdatedAt('books', id);
      await this.db.rdbHandle.execute(
        `UPDATE books
           SET deleted_at = ?, is_vectorized = 0, vectorize_progress = 0,
               updated_at = ?, sync_version = ?, last_modified_by = ?
         WHERE id = ?`,
        [deletedAt, updatedAt, syncVersion, deviceId, id],
      );
    });
  }

  /**
   * Delete a book and everything belonging to it.
   *
   * The local rows are removed outright and a tombstone is written for the book.
   * Annotation tombstones are deliberately not written individually: the per-book
   * sync file represents the whole book's deletion with the book's own index
   * marker `d`, and a peer that sees it deletes the book and every annotation in
   * it. One tombstone per annotation would be redundant traffic for that outcome.
   *
   * The five statements run as one retried, serialized unit. Without that, a failure
   * part-way leaves annotations whose book row is already gone: unreachable through the
   * UI, still counted by the index's `a` marker, and re-uploaded on every push because
   * nothing local can match them to a book.
   *
   * Child deletes are explicit rather than relying on `ON DELETE CASCADE`, for the
   * reason this method has always given: the cascade depends on a pragma having taken
   * effect, and this must not.
   */
  async deleteBook(id: string): Promise<void> {
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      await this.db.insertTombstone(id, 'books');
      for (const table of ['highlights', 'notes', 'bookmarks']) {
        await this.db.rdbHandle.execute(`DELETE FROM ${table} WHERE book_id = ?`, [id]);
      }
      await this.db.rdbHandle.execute('DELETE FROM books WHERE id = ?', [id]);
    });
  }

  /**
   * Max annotation `updated_at` per book, for the index's `a` marker.
   *
   * One grouped query per table rather than a query per book: the marker is
   * needed for every book on every sync, so a per-book query would be O(books)
   * round trips.
   */
  async annotationMarkers(): Promise<Map<string, number>> {
    const markers: Map<string, number> = new Map<string, number>();
    for (const table of ['highlights', 'notes', 'bookmarks']) {
      if (!(await this.db.hasTable(table))) {
        continue;
      }
      const pairs: BookMarker[] = await this.db.rdbHandle.select<BookMarker>(
        `SELECT book_id AS book_id, MAX(updated_at) AS max_ts FROM ${table} GROUP BY book_id`,
        (row: Row): BookMarker => {
          const marker: BookMarker = { bookId: row.str('book_id'), maxTs: row.num('max_ts') };
          return marker;
        },
      );
      for (const pair of pairs) {
        const existing: number = markers.get(pair.bookId) ?? 0;
        markers.set(pair.bookId, Math.max(existing, pair.maxTs));
      }
    }
    return markers;
  }

  /** Annotation counts for one book, for the detail screen. */
  async annotationCounts(bookId: string): Promise<AnnotationCounts> {
    const rdb = this.db.rdbHandle;
    const counts: AnnotationCounts = { bookmarks: 0, highlights: 0, notes: 0 };
    counts.bookmarks = Number(
      await rdb.scalar('SELECT COUNT(*) FROM bookmarks WHERE book_id = ?', [bookId]),
    );
    counts.highlights = Number(
      await rdb.scalar('SELECT COUNT(*) FROM highlights WHERE book_id = ?', [bookId]),
    );
    counts.notes = Number(await rdb.scalar('SELECT COUNT(*) FROM notes WHERE book_id = ?', [bookId]));
    return counts;
  }

  /**
   * Remove a book because a peer deleted it.
   *
   * The guard matters: a local edit made *after* the remote deletion must survive
   * and travel back up as a resurrection, exactly as the per-row rule does for
   * annotations. `deletedAt >= localUpdatedAt` is the same comparison the
   * reference engine applies before deleting a book.
   *
   * Returns true when the deletion was applied.
   */
  /**
   * Delete a book because a peer deleted it.
   *
   * The whole cascade runs as one retried, serialized unit, for the same reason
   * `deleteBook` does: four independent writes that must not be interrupted half-way,
   * or the annotations survive with no book row to reach them through. Phase 0's
   * orphan cleanup would eventually collect them, but leaving that to a later pass
   * means the index's `a` marker counts them in the meantime.
   *
   * The tombstone is recorded inside the transaction as well: it is what stops the
   * deletion from being resurrected by the next push, so it must land with the delete
   * rather than after it.
   */
  async deleteCascadeFromRemote(bookId: string, deletedAt: number, deviceId: string): Promise<boolean> {
    const local: Book | undefined = await this.getById(bookId);
    if (local === undefined) {
      return false;
    }
    // Destructive and irreversible: this deletes the row plus every annotation it
    // owns and records a sticky tombstone, and the index marker it came from is not
    // lowered, so no later re-pull restores anything. An implausible future
    // timestamp is therefore refused *before* the ordering test below — the
    // ordering test alone passes for any fabricated value, because `9e15` is newer
    // than every real `updated_at`. Callers log the refusal; this method is also a
    // public entry point, so it does not rely on them having checked.
    if (!isPlausibleTombstone(deletedAt, Date.now())) {
      return false;
    }
    if (deletedAt < local.updatedAt) {
      // Edited here more recently than the peer deleted it — keep it.
      return false;
    }

    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      // Cascade by hand rather than relying on `ON DELETE CASCADE`: the foreign-key
      // pragma is a tuning step that may not have taken effect.
      for (const table of ['highlights', 'notes', 'bookmarks']) {
        await this.db.rdbHandle.execute(`DELETE FROM ${table} WHERE book_id = ?`, [bookId]);
      }
      await this.db.rdbHandle.execute('DELETE FROM books WHERE id = ?', [bookId]);
      await this.db.rememberRemoteTombstone(bookId, 'books', deletedAt, deviceId, undefined);
    });
    return true;
  }

  // -------------------------------------------------------------------------
  // Remote application
  // -------------------------------------------------------------------------

  /**
   * Apply a book row that arrived from a peer.
   *
   * Two local-vs-remote rules from ReadAny are preserved:
   *  1. last-write-wins on `updated_at`, with `deleted_at` breaking ties.
   *  2. A locally customised cover is not overwritten by the peer's canonical
   *     cover path — the user chose that image and a peer has no opinion on it.
   *
   * `file_path` and `sync_status` are rewritten to local values. The remote row
   * carries the *writer's* sandbox path, which is meaningless on this device, and
   * whether a file is present is a local fact.
   */
  async applyRemoteBook(
    record: Record<string, Object>,
    forceApply: boolean,
    keepLocalCover: boolean,
  ): Promise<boolean> {
    const reader: RecordReader = jsonReader(record);
    const id: string = reader.str('id');
    if (id.length === 0) {
      return false;
    }

    const local: Book | undefined = await this.getById(id);
    const localState = local !== undefined
      ? localRecordState(local.updatedAt, local.deletedAt > 0 ? local.deletedAt : null)
      : undefined;

    if (!forceApply && !shouldApplyRemoteRecord(reader, 'updated_at', localState)) {
      return false;
    }

    const remote: Book = toBook(reader);
    let coverUrl: string = remote.coverUrl;
    if (
      keepLocalCover &&
      local !== undefined &&
      isCustomCoverPath(id, local.coverUrl) &&
      !isCustomCoverPath(id, remote.coverUrl) &&
      isCanonicalCoverPath(id, remote.coverUrl)
    ) {
      coverUrl = local.coverUrl;
    }

    const localFilePath: string = local !== undefined ? local.filePath : remote.filePath;
    const syncStatus: string = local !== undefined && local.syncStatus === 'local'
      ? 'local'
      : (remote.syncStatus === 'local' ? 'remote' : remote.syncStatus);

    // No object spread in ArkTS: copy, then override the fields that must not be
    // taken from the peer.
    const applied: Book = copyBook(remote);
    applied.coverUrl = coverUrl;

    // A tombstoned book is written exactly as the peer sent it. Localizing it would
    // claim this device has a file at `localFilePath` and mark it `local` — for a book
    // whose file may already be gone, and which the binary pass would then treat as
    // present. The deletion is the fact being applied; nothing else about the row is
    // this device's business.
    if (applied.deletedAt <= 0) {
      applied.filePath = localFilePath;
      applied.syncStatus = syncStatus === 'local' ? 'local' : 'remote';
    }

    // The upsert does NOT bump `updated_at`: the remote timestamp is the truth
    // being applied. Bumping it would make this device look newer than the peer
    // and re-publish the peer's own change back to it on every pass.
    const writerDeviceId: string = reader.str('last_modified_by');
    await this.writeRow(
      applied,
      await this.db.nextSyncVersion('books'),
      writerDeviceId.length > 0 ? writerDeviceId : await this.db.getDeviceId(),
    );
    return true;
  }

  /** Single place that builds the `books` upsert, so both write paths agree. */
  private async writeRow(book: Book, syncVersion: number, deviceId: string): Promise<void> {
    const placeholders: string = BOOK_COLUMNS.map((): string => '?').join(', ');
    const updateSet: string =
      BOOK_COLUMNS.filter((c: string): boolean => c !== 'id')
        .map((c: string): string => `${c} = excluded.${c}`)
        .join(', ');
    await this.db.rdbHandle.execute(
      `INSERT INTO books (${BOOK_COLUMNS.join(', ')}) VALUES (${placeholders})
       ON CONFLICT(id) DO UPDATE SET ${updateSet}`,
      bookValues(book, syncVersion, deviceId),
    );
  }
}

/**
 * True for a cover the user supplied, which lives next to the book as
 * `covers/{id}-custom-*`.
 */
export function isCustomCoverPath(bookId: string, value: string): boolean {
  return value.startsWith(`covers/${bookId}-custom-`);
}

/** True for the cover extracted from the book itself: `covers/{id}.{ext}`. */
export function isCanonicalCoverPath(bookId: string, value: string): boolean {
  return value.startsWith(`covers/${bookId}.`);
}

/**
 * Field-by-field copy of a book.
 *
 * Stands in for the object spread that ArkTS does not support. Written out
 * explicitly rather than via a generic helper so that adding a field to `Book`
 * fails to compile here until it is handled, instead of being silently dropped.
 */
export function copyBook(source: Book): Book {
  const copy: Book = {
    id: source.id,
    filePath: source.filePath,
    format: source.format,
    title: source.title,
    author: source.author,
    publisher: source.publisher,
    language: source.language,
    isbn: source.isbn,
    description: source.description,
    coverUrl: source.coverUrl,
    publishDate: source.publishDate,
    rating: source.rating,
    reviews: source.reviews,
    subjects: source.subjects,
    totalPages: source.totalPages,
    totalChapters: source.totalChapters,
    groupId: source.groupId,
    addedAt: source.addedAt,
    lastOpenedAt: source.lastOpenedAt,
    updatedAt: source.updatedAt,
    deletedAt: source.deletedAt,
    progress: source.progress,
    currentCfi: source.currentCfi,
    currentSpine: source.currentSpine,
    currentDomPos: source.currentDomPos,
    tags: source.tags.slice(),
    fileHash: source.fileHash,
    syncStatus: source.syncStatus,
  };
  return copy;
}
