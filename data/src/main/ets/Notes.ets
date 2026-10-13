/**
 * Note repository.
 *
 * Ported from ReadAny `packages/core/src/db/note-queries.ts`. A note may be
 * anchored to a highlight (`highlightId`) and/or to a position (`cfi`), or float
 * free of both — a standalone note about the book as a whole.
 */

import type { RecordReader } from 'core';
import { generateId, jsonReader, sortAnnotationsByPosition } from 'core';
import { localRecordState, shouldApplyRemoteRecord, shouldApplyTombstone } from 'sync';
import type { Database } from './Database';
import type { Row } from './Rdb';
import { sqlReader } from './RecordReader';
import { NOTE_COLUMNS, noteToSyncRecord, noteValues, toNote } from './Records';
import type { Note } from './Types';

export class Notes {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /** All notes of one book, in document order. */
  async listForBook(bookId: string): Promise<Note[]> {
    const rows: Note[] = await this.db.rdbHandle.select<Note>(
      'SELECT * FROM notes WHERE book_id = ?',
      (row: Row): Note => toNote(sqlReader(row)),
      [bookId],
    );
    return sortAnnotationsByPosition(rows);
  }

  /**
   * Notes across every book, most recently updated first.
   *
   * Deliberately NOT position-sorted: this feeds a global list where document
   * position is meaningless and recency is what the user expects. The reference
   * client's `getAllNotes` likewise skips the re-sort.
   */
  async listRecent(limit: number): Promise<Note[]> {
    return await this.db.rdbHandle.select<Note>(
      'SELECT * FROM notes ORDER BY updated_at DESC LIMIT ?',
      (row: Row): Note => toNote(sqlReader(row)),
      [limit],
    );
  }

  async getById(id: string): Promise<Note | undefined> {
    const rows: Note[] = await this.db.rdbHandle.select<Note>(
      'SELECT * FROM notes WHERE id = ?',
      (row: Row): Note => toNote(sqlReader(row)),
      [id],
    );
    return rows.length > 0 ? rows[0] : undefined;
  }

  async add(
    bookId: string,
    content: string,
    title: string,
    highlightId: string,
    cfi: string,
    chapterTitle: string,
    tags: string[],
  ): Promise<Note> {
    const now: number = Date.now();
    const note: Note = {
      id: generateId(),
      bookId: bookId,
      highlightId: highlightId,
      cfi: cfi,
      title: title,
      content: content,
      chapterTitle: chapterTitle,
      tags: tags,
      createdAt: now,
      updatedAt: now,
    };
    await this.insert(note);
    return note;
  }

  async insert(note: Note): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('notes');
    const placeholders: string = NOTE_COLUMNS.map((): string => '?').join(', ');
    await this.db.rdbHandle.execute(
      `INSERT OR REPLACE INTO notes (${NOTE_COLUMNS.join(', ')}) VALUES (${placeholders})`,
      noteValues(note, syncVersion, deviceId),
    );
  }

  /**
   * Update the editable fields.
   *
   * `highlightId` and `cfi` are not editable: re-anchoring a note is not an
   * update, it is a different note, and allowing it here would make the sync
   * payload's anchoring ambiguous.
   */
  async update(id: string, title: string, content: string, tags: string[]): Promise<void> {
    const deviceId: string = await this.db.getDeviceId();
    const syncVersion: number = await this.db.nextSyncVersion('notes');
    const updatedAt: number = await this.db.nextUpdatedAt('notes', id);
    await this.db.rdbHandle.execute(
      `UPDATE notes SET title = ?, content = ?, tags = ?, updated_at = ?, sync_version = ?,
        last_modified_by = ? WHERE id = ?`,
      [title, content, JSON.stringify(tags), updatedAt, syncVersion, deviceId, id],
    );
  }

  /**
   * Delete a note and record its tombstone as one unit.
   *
   * The two statements are ordered tombstone-first and now run together. Ordering
   * alone would mostly work — a tombstone whose row still exists is filtered out of
   * the upload map, so the deletion is retried on the next pass — but a failure
   * between them briefly presents a state where the note is neither deleted nor
   * advertised as deleted. Wrapping removes the window instead of relying on the next
   * pass to close it.
   */
  async remove(id: string): Promise<void> {
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      const existing: Note | undefined = await this.getById(id);
      await this.db.insertTombstone(
        id,
        'notes',
        existing !== undefined ? existing.bookId : undefined,
      );
      await this.db.rdbHandle.execute('DELETE FROM notes WHERE id = ?', [id]);
    });
  }

  async listAll(): Promise<Note[]> {
    return await this.db.rdbHandle.select<Note>(
      'SELECT * FROM notes',
      (row: Row): Note => toNote(sqlReader(row)),
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
    const local: Note | undefined = await this.getById(id);
    const localState = local !== undefined
      ? localRecordState(local.updatedAt, null)
      : undefined;
    if (!forceApply && !shouldApplyRemoteRecord(reader, 'updated_at', localState)) {
      return false;
    }

    const remote: Note = toNote(reader);
    const placeholders: string = NOTE_COLUMNS.map((): string => '?').join(', ');
    const writer: string = reader.str('last_modified_by');
    await this.db.rdbHandle.execute(
      `INSERT OR REPLACE INTO notes (${NOTE_COLUMNS.join(', ')}) VALUES (${placeholders})`,
      noteValues(remote, await this.db.nextSyncVersion('notes'),
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
    const local: Note | undefined = await this.getById(id);
    if (local === undefined) {
      return false;
    }
    if (!shouldApplyTombstone(deletedAt, local.updatedAt, forceApply)) {
      return false;
    }
    // The delete and the tombstone it implies are one unit. Both writes are
    // individually retried, but a failure between them leaves the row gone while
    // nothing local records *why* — so the peer would re-create it on its next push
    // and the deletion would silently undo itself.
    await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
      await this.db.rdbHandle.execute('DELETE FROM notes WHERE id = ?', [id]);
      await this.db.rememberRemoteTombstone(id, 'notes', deletedAt, deviceId, bookId);
    });
    return true;
  }
}
