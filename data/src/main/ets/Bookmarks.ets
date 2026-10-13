/**
 * Bookmark repository.
 *
 * Ported from ReadAny `packages/core/src/db/bookmark-queries.ts`.
 *
 * Sorting note: the reference SQL orders by `created_at DESC` and then re-sorts
 * in JS by document position, which makes the SQL ordering dead weight. This port
 * keeps the JS sort as the single source of order — the list arrives in book
 * order, which is what the UI shows and what "next bookmark" means.
 */

import type { RecordReader } from 'core';
import { generateId, jsonReader, sortAnnotationsByPosition } from 'core';
import { localRecordState, shouldApplyRemoteRecord, shouldApplyTombstone } from 'sync';
import type { Database } from './Database';
import type { Row } from './Rdb';
import { sqlReader } from './RecordReader';
import { BOOKMARK_COLUMNS, bookmarkToSyncRecord, bookmarkValues, toBookmark } from './Records';
import type { Bookmark } from './Types';

export class Bookmarks {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /** All bookmarks of one book, in document order. */
  async listForBook(bookId: string): Promise<Bookmark[]> {
    const rows: Bookmark[] = await this.db.rdbHandle.select<Bookmark>(
      'SELECT * FROM bookmarks WHERE book_id = ?',
      (row: Row): Bookmark => toBookmark(sqlReader(row)),
      [bookId],
    );
    return sortAnnotationsByPosition(rows);
  }

  async getById(id: string): Promise<Bookmark | undefined> {
    const rows: Bookmark[] = await this.db.rdbHandle.select<Bookmark>(
      'SELECT * FROM bookmarks WHERE id = ?',
      (row: Row): Bookmark => toBookmark(sqlReader(row)),
      [id],
    );
    return rows.length > 0 ? rows[0] : undefined;
  }

  /**
   * Create from a position, filling in the fields the caller does not produce.
   *
   * `createdAt` and `updatedAt` start equal, matching the reference client's
   * `updated_at = max(now, created_at)` on insert.
   */
  async add(bookId: string, cfi: string, label: string, chapterTitle: string): Promise<Bookmark> {
    const now: number = Date.now();
    const bookmark: Bookmark = {
      id: generateId(),
      bookId: bookId,
      cfi: cfi,
      label: label,
      chapterTitle: chapterTitle,
      createdAt: now,
      updatedAt: now,
    };
    await this.insert(bookmark);
    return bookmark;
  }

  async insert(bookmark: Bookmark): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('bookmarks');
    const updatedAt: number = Math.max(Date.now(), bookmark.createdAt);
    // ArkTS has no object spread (`arkts-no-spread`).
    const stored: Bookmark = {
      id: bookmark.id,
      bookId: bookmark.bookId,
      cfi: bookmark.cfi,
      label: bookmark.label,
      chapterTitle: bookmark.chapterTitle,
      createdAt: bookmark.createdAt,
      updatedAt: updatedAt,
    };

    const placeholders: string = BOOKMARK_COLUMNS.map((): string => '?').join(', ');
    await this.db.rdbHandle.execute(
      `INSERT OR REPLACE INTO bookmarks (${BOOKMARK_COLUMNS.join(', ')}) VALUES (${placeholders})`,
      bookmarkValues(stored, syncVersion, deviceId),
    );
  }

  /** Rename or relabel an existing bookmark. */
  async updateLabel(id: string, label: string): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('bookmarks');
    const updatedAt: number = await this.db.nextUpdatedAt('bookmarks', id);
    await this.db.rdbHandle.execute(
      `UPDATE bookmarks SET label = ?, updated_at = ?, sync_version = ?, last_modified_by = ?
       WHERE id = ?`,
      [label.length > 0 ? label : null, updatedAt, syncVersion, deviceId, id],
    );
  }

  /**
   * Delete with a tombstone so the deletion propagates instead of coming back.
   *
   * Both statements run as one unit; see `Notes.remove` for why a window between them
   * is worth closing rather than relying on the next sync pass.
   */
  async remove(id: string): Promise<void> {
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      const existing: Bookmark | undefined = await this.getById(id);
      await this.db.insertTombstone(
        id,
        'bookmarks',
        existing !== undefined ? existing.bookId : undefined,
      );
      await this.db.rdbHandle.execute('DELETE FROM bookmarks WHERE id = ?', [id]);
    });
  }

  /** Every bookmark, used to build per-book sync files. */
  async listAll(): Promise<Bookmark[]> {
    return await this.db.rdbHandle.select<Bookmark>(
      'SELECT * FROM bookmarks',
      (row: Row): Bookmark => toBookmark(sqlReader(row)),
    );
  }



  /**
   * Apply a remote bookmark.
   *
   * Returns true when the local row changed. `forceApply` bypasses the timestamp
   * comparison for the "overwrite local from remote" recovery path.
   */
  async applyRemote(
    record: Record<string, Object>,
    forceApply: boolean,
    deviceId: string,
  ): Promise<boolean> {
    const reader: RecordReader = jsonReader(record);
    const id: string = reader.str('id');
    if (id.length === 0) {
      return false;
    }

    const local: Bookmark | undefined = await this.getById(id);
    const localState = local !== undefined
      ? localRecordState(local.updatedAt, null)
      : undefined;
    if (!forceApply && !shouldApplyRemoteRecord(reader, 'updated_at', localState)) {
      return false;
    }

    const remote: Bookmark = toBookmark(reader);
    const placeholders: string = BOOKMARK_COLUMNS.map((): string => '?').join(', ');
    const writer: string = reader.str('last_modified_by');
    await this.db.rdbHandle.execute(
      `INSERT OR REPLACE INTO bookmarks (${BOOKMARK_COLUMNS.join(', ')}) VALUES (${placeholders})`,
      bookmarkValues(remote, await this.db.nextSyncVersion('bookmarks'),
        writer.length > 0 ? writer : deviceId),
    );
    return true;
  }

  /**
   * Apply a tombstone that arrived inside a book's sync file.
   *
   * `deletedAt >= localUpdatedAt` preserves the reference rule: a local edit made
   * after the remote deletion survives and travels back up as a resurrection on
   * the next push.
   */
  async applyRemoteDeletion(
    id: string,
    deletedAt: number,
    deviceId: string,
    bookId: string,
    forceApply: boolean,
  ): Promise<boolean> {
    const local: Bookmark | undefined = await this.getById(id);
    if (local === undefined) {
      return false;
    }
    if (!shouldApplyTombstone(deletedAt, local.updatedAt, forceApply)) {
      return false;
    }
    // One unit: see Notes.applyRemoteDeletion for why the delete and the
    // tombstone must land together.
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      await this.db.rdbHandle.execute('DELETE FROM bookmarks WHERE id = ?', [id]);
      await this.db.rememberRemoteTombstone(id, 'bookmarks', deletedAt, deviceId, bookId);
    });
    return true;
  }
}

/**
 * Document order for a bookmark list.
 *
 * Delegates to the shared comparator so bookmarks, highlights and notes cannot
 * drift apart in how they interpret a CFI.
 */
export function sortByPosition(items: Bookmark[]): Bookmark[] {
  return sortAnnotationsByPosition(items);
}
