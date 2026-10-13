/**
 * Highlight repository.
 *
 * Ported from ReadAny `packages/core/src/db/highlight-queries.ts`. A highlight is
 * a range in the book plus optional inline note text; a separate `Note` row is
 * used when the user writes a longer note anchored to the highlight.
 */

import type { RecordReader } from 'core';
import { generateId, jsonReader, sortAnnotationsByPosition } from 'core';
import { localRecordState, shouldApplyRemoteRecord, shouldApplyTombstone } from 'sync';
import type { Database } from './Database';
import type { Row } from './Rdb';
import { sqlReader } from './RecordReader';
import { HIGHLIGHT_COLUMNS, highlightToSyncRecord, highlightValues, toHighlight } from './Records';
import type { Highlight, HighlightColor } from './Types';

export class Highlights {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /** All highlights of one book, in document order. */
  async listForBook(bookId: string): Promise<Highlight[]> {
    const rows: Highlight[] = await this.db.rdbHandle.select<Highlight>(
      'SELECT * FROM highlights WHERE book_id = ?',
      (row: Row): Highlight => toHighlight(sqlReader(row)),
      [bookId],
    );
    return sortAnnotationsByPosition(rows);
  }

  async getById(id: string): Promise<Highlight | undefined> {
    const rows: Highlight[] = await this.db.rdbHandle.select<Highlight>(
      'SELECT * FROM highlights WHERE id = ?',
      (row: Row): Highlight => toHighlight(sqlReader(row)),
      [id],
    );
    return rows.length > 0 ? rows[0] : undefined;
  }

  /** Insert a highlight for a selected range. */
  async add(
    bookId: string,
    cfi: string,
    text: string,
    color: HighlightColor,
    note: string,
    chapterTitle: string,
  ): Promise<Highlight> {
    const now: number = Date.now();
    const highlight: Highlight = {
      id: generateId(),
      bookId: bookId,
      cfi: cfi,
      text: text,
      color: color,
      note: note,
      chapterTitle: chapterTitle,
      createdAt: now,
      updatedAt: now,
    };
    await this.insert(highlight);
    return highlight;
  }

  async insert(highlight: Highlight): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('highlights');
    const placeholders: string = HIGHLIGHT_COLUMNS.map((): string => '?').join(', ');
    await this.db.rdbHandle.execute(
      `INSERT OR REPLACE INTO highlights (${HIGHLIGHT_COLUMNS.join(', ')}) VALUES (${placeholders})`,
      highlightValues(highlight, syncVersion, deviceId),
    );
  }

  /**
   * Update a highlight in place.
   *
   * Only the mutable fields are written. `cfi`, `text` and `created_at` are
   * immutable by construction: the anchor and the quoted text are what the user
   * selected, and rewriting them would orphan the annotation in the book.
   */
  async update(id: string, color: HighlightColor, note: string): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('highlights');
    const updatedAt: number = await this.db.nextUpdatedAt('highlights', id);
    await this.db.rdbHandle.execute(
      `UPDATE highlights SET color = ?, note = ?, updated_at = ?, sync_version = ?, last_modified_by = ?
       WHERE id = ?`,
      [color, note.length > 0 ? note : null, updatedAt, syncVersion, deviceId, id],
    );
  }

  /**
   * Delete a highlight and record its tombstone as one unit.
   *
   * See `Notes.remove` for why the two statements are wrapped: ordering alone leaves a
   * window where the row is neither deleted nor advertised as deleted.
   */
  async remove(id: string): Promise<void> {
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      const existing: Highlight | undefined = await this.getById(id);
      await this.db.insertTombstone(
        id,
        'highlights',
        existing !== undefined ? existing.bookId : undefined,
      );
      await this.db.rdbHandle.execute('DELETE FROM highlights WHERE id = ?', [id]);
    });
  }

  async listAll(): Promise<Highlight[]> {
    return await this.db.rdbHandle.select<Highlight>(
      'SELECT * FROM highlights',
      (row: Row): Highlight => toHighlight(sqlReader(row)),
    );
  }



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
    const local: Highlight | undefined = await this.getById(id);
    const localState = local !== undefined
      ? localRecordState(local.updatedAt, null)
      : undefined;
    if (!forceApply && !shouldApplyRemoteRecord(reader, 'updated_at', localState)) {
      return false;
    }

    const remote: Highlight = toHighlight(reader);
    const placeholders: string = HIGHLIGHT_COLUMNS.map((): string => '?').join(', ');
    const writer: string = reader.str('last_modified_by');
    await this.db.rdbHandle.execute(
      `INSERT OR REPLACE INTO highlights (${HIGHLIGHT_COLUMNS.join(', ')}) VALUES (${placeholders})`,
      highlightValues(remote, await this.db.nextSyncVersion('highlights'),
        writer.length > 0 ? writer : deviceId),
    );
    return true;
  }

  async applyRemoteDeletion(
    id: string,
    deletedAt: number,
    deviceId: string,
    bookId: string,
    forceApply: boolean,
  ): Promise<boolean> {
    const local: Highlight | undefined = await this.getById(id);
    if (local === undefined) {
      return false;
    }
    if (!shouldApplyTombstone(deletedAt, local.updatedAt, forceApply)) {
      return false;
    }
    // One unit: see Notes.applyRemoteDeletion for why the delete and the
    // tombstone must land together.
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      await this.db.rdbHandle.execute('DELETE FROM highlights WHERE id = ?', [id]);
      await this.db.rememberRemoteTombstone(id, 'highlights', deletedAt, deviceId, bookId);
    });
    return true;
  }
}
