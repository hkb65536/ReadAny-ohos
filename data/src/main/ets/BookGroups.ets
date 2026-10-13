/**
 * Shelf-group repository.
 *
 * `book_groups` is the one profile table this client syncs. It carries the same sync
 * field set as a book row (`updated_at`, `sync_version`, `last_modified_by`), so it
 * merges by exactly the same rule and reuses the same helpers.
 *
 * The table exists because `books.group_id` is only a reference: without it a book
 * can say it belongs to a group but nothing can say what the group is called.
 *
 * `tags` and `book_tags` are deliberately not modelled. They carry no `updated_at`,
 * and `book_tags` is a bare join table, so there is no timestamp for the merge rule to
 * compare. Guessing one would risk damaging data this client otherwise leaves alone.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { generateId, InkBoatError, jsonReader, SyncErrorKind } from 'core';
import {
  isPlausibleTombstone,
  localRecordState,
  MAX_FUTURE_TOMBSTONE_SKEW_MS,
  shouldApplyRemoteRecord,
  shouldApplyTombstone,
} from 'sync';
import type { LocalRecordState } from 'sync';
import type { Database } from './Database';
import type { Row } from './Rdb';
import { sqlReader } from './RecordReader';
import { bookGroupFromWire, bookGroupToSyncRecord, toBookGroup } from './Records';
import type { BookGroup } from './Types';
import { BOOK_GROUP_COLUMNS } from './Types';

/** Remote table name, matching the reference layout. */
/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatGroups';

export const BOOK_GROUPS_TABLE: string = 'book_groups';

/** The column the merge compares. */
export const BOOK_GROUP_TIMESTAMP_KEY: string = 'updated_at';

/** Selection list, in DDL order. */
const SELECT_COLUMNS: string = BOOK_GROUP_COLUMNS.join(', ');

/** Re-wrap a caught value, since ArkTS forbids rethrowing it unchanged. */
function fail(action: string, err: Object): InkBoatError {
  if (err instanceof InkBoatError) {
    return err;
  }
  const message: string = err instanceof Error ? err.message : JSON.stringify(err);
  return new InkBoatError(SyncErrorKind.DATABASE, `${action}：${message}`);
}

export class BookGroups {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /** Every group, ordered for display. */
  async listAll(): Promise<BookGroup[]> {
    try {
      return await this.db.rdbHandle.select<BookGroup>(
        `SELECT ${SELECT_COLUMNS} FROM book_groups
         ORDER BY sort_order ASC, name ASC`,
        (row: Row): BookGroup => toBookGroup(sqlReader(row)),
      );
    } catch (err) {
      throw fail('读取分组失败', err as Object);
    }
  }

  async getById(id: string): Promise<BookGroup | undefined> {
    try {
      const groups: BookGroup[] = await this.db.rdbHandle.select<BookGroup>(
        `SELECT ${SELECT_COLUMNS} FROM book_groups WHERE id = ?`,
        (row: Row): BookGroup => toBookGroup(sqlReader(row)),
        [id],
      );
      return groups.length > 0 ? groups[0] : undefined;
    } catch (err) {
      throw fail('读取分组失败', err as Object);
    }
  }

  /** Create a group and return it. */
  async add(name: string, sortOrder: number): Promise<BookGroup> {
    const now: number = Date.now();
    const group: BookGroup = {
      id: generateId(),
      name: name,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
      syncVersion: await this.db.nextSyncVersion(BOOK_GROUPS_TABLE),
      lastModifiedBy: await this.db.getDeviceId(),
    };
    await this.insert(group);
    return group;
  }

  /**
   * Write a group row.
   *
   * `created_at` is excluded from the update arm on purpose: a remote row that has
   * lost its `created_at` would otherwise overwrite a real value with 0 through the
   * conflict path, and creation time never legitimately changes.
   */
  async insert(group: BookGroup): Promise<void> {
    try {
      const placeholders: string[] = [];
      for (let i = 0; i < BOOK_GROUP_COLUMNS.length; i++) {
        placeholders.push('?');
      }
      await this.db.rdbHandle.execute(
        `INSERT INTO book_groups (${SELECT_COLUMNS})
         VALUES (${placeholders.join(', ')})
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           sort_order = excluded.sort_order,
           updated_at = excluded.updated_at,
           sync_version = excluded.sync_version,
           last_modified_by = excluded.last_modified_by`,
        [
          group.id,
          group.name,
          group.sortOrder,
          group.createdAt,
          group.updatedAt,
          group.syncVersion,
          group.lastModifiedBy,
        ],
      );
    } catch (err) {
      throw fail('保存分组失败', err as Object);
    }
  }

  /**
   * Rename a group.
   *
   * Bumps `updated_at` and `sync_version` so the change wins its next merge and is
   * offered for upload.
   */
  async rename(id: string, name: string): Promise<void> {
    const syncVersion: number = await this.db.nextSyncVersion(BOOK_GROUPS_TABLE);
    const updatedAt: number = await this.db.nextUpdatedAt(BOOK_GROUPS_TABLE, id);
    try {
      await this.db.rdbHandle.execute(
        `UPDATE book_groups SET name = ?, updated_at = ?, sync_version = ?,
           last_modified_by = ? WHERE id = ?`,
        [name, updatedAt, syncVersion, await this.db.getDeviceId(), id],
      );
    } catch (err) {
      throw fail('重命名分组失败', err as Object);
    }
  }

  /**
   * Delete a group.
   *
   * A tombstone is recorded, not just the row removed: a peer would otherwise re-add
   * the group on its next upload, because from its side the row still exists.
   *
   * `books.group_id` is left pointing at the removed group. There is no foreign key
   * there in the reference schema, and clearing it would mean rewriting book rows
   * whose own timestamps have not changed — which would make every affected book look
   * locally modified and push them all on the next sync.
   */
  async remove(id: string): Promise<void> {
    try {
      await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
        await this.db.rdbHandle.execute('DELETE FROM book_groups WHERE id = ?', [id]);
        await this.db.insertTombstone(id, BOOK_GROUPS_TABLE);
      });
    } catch (err) {
      throw fail('删除分组失败', err as Object);
    }
  }

  /**
   * Tombstones for this table, as the wire `deleted` map.
   *
   * Restricted to ids with no surviving row, matching how the annotation tables build
   * theirs: a row that was deleted and then re-created must not also be advertised as
   * deleted, or a peer would remove the re-created row.
   */
  async tombstones(): Promise<Map<string, number>> {
    const result: Map<string, number> = new Map<string, number>();
    let pairs: TombstonePair[] = [];
    try {
      pairs = await this.db.rdbHandle.select<TombstonePair>(
        `SELECT t.id AS id, t.deleted_at AS deleted_at
         FROM sync_tombstones t
         WHERE t.table_name = ?
           AND NOT EXISTS (SELECT 1 FROM book_groups g WHERE g.id = t.id)`,
        (row: Row): TombstonePair => {
          const pair: TombstonePair = {
            id: row.str('id'),
            deletedAt: row.num('deleted_at'),
          };
          return pair;
        },
        [BOOK_GROUPS_TABLE],
      );
    } catch (err) {
      // A tombstone read failure must not block the upload: the worst case is a
      // deletion that never propagates, which is recoverable on the next pass.
      pairs = [];
    }
    for (const pair of pairs) {
      result.set(pair.id, pair.deletedAt);
    }
    return result;
  }

  /** All rows as wire records, for the profile file. */
  async toWireRows(): Promise<Record<string, Object>[]> {
    const groups: BookGroup[] = await this.listAll();
    const rows: Record<string, Object>[] = [];
    for (const group of groups) {
      rows.push(bookGroupToSyncRecord(group));
    }
    return rows;
  }

  /**
   * Apply a merged set of wire rows.
   *
   * The decision reuses `shouldApplyRemoteRecord`, the same rule the book and
   * annotation tables use, rather than a hand-written `>=`. Sharing it matters: if
   * this path disagreed about ties, a group would flip back and forth between two
   * devices on every sync. It takes a `FieldReader` over the *wire* record, which is
   * why the raw row is passed through `jsonReader` rather than read by hand.
   */
  async applyRemoteRows(
    rows: Record<string, Object>[],
    forceApply: boolean,
  ): Promise<number> {
    let applied: number = 0;
    for (const row of rows) {
      const incoming: BookGroup = bookGroupFromWire(row);
      if (incoming.id.length === 0) {
        continue;
      }
      const local: BookGroup | undefined = await this.getById(incoming.id);
      const state: LocalRecordState | undefined = local !== undefined
        ? localRecordState(local.updatedAt, null)
        : undefined;
      if (!shouldApplyRemoteRecord(jsonReader(row), BOOK_GROUP_TIMESTAMP_KEY, state)) {
        continue;
      }
      await this.insert(incoming);
      applied++;
    }
    return applied;
  }

  /**
   * Apply remote deletions.
   *
   * `shouldApplyTombstone` decides, exactly as for annotations: a group edited after
   * the tombstone was written survives and is offered for upload again — the
   * resurrection rule. Applying unconditionally would let a stale deletion destroy a
   * newer rename.
   */
  async applyRemoteDeletions(
    deleted: Map<string, number>,
    deviceId: string,
    forceApply: boolean,
  ): Promise<number> {
    let applied: number = 0;
    // One clock reading for the whole map: every tombstone in one remote profile
    // file must be judged against the same "now".
    const now: number = Date.now();
    for (const entry of deleted.entries()) {
      const id: string = entry[0];
      const deletedAt: number = entry[1];
      // Third tombstone path, same weakness as the book index and the per-book
      // annotation map: `shouldApplyTombstone` only compares ordering, so a
      // fabricated `9e15` would win against every real `updatedAt`. Refused before
      // the ordering test and logged, so a corrupt profile file cannot delete a
      // group that the user cannot get back.
      if (!isPlausibleTombstone(deletedAt, now)) {
        hilog.warn(DOMAIN, TAG,
          'ignoring implausible remote group deletion for %{public}s: deletedAt=%{public}s is beyond now + %{public}s ms',
          id, String(deletedAt), String(MAX_FUTURE_TOMBSTONE_SKEW_MS));
        continue;
      }
      const local: BookGroup | undefined = await this.getById(id);
      const localUpdatedAt: number = local !== undefined ? local.updatedAt : 0;
      if (!shouldApplyTombstone(deletedAt, localUpdatedAt, forceApply)) {
        continue;
      }
      try {
        await this.db.rdbHandle.writeTransaction(async (): Promise<void> => {
          await this.db.rdbHandle.execute('DELETE FROM book_groups WHERE id = ?', [id]);
          await this.db.rememberRemoteTombstone(id, BOOK_GROUPS_TABLE, deletedAt, deviceId);
        });
        applied++;
      } catch (err) {
        // One failed delete must not abort the rest of the profile; the tombstone
        // stays in the remote file and is retried next pass. Logged because a group
        // that will not disappear is user-visible, and without a line here it looks
        // like the deletion silently did nothing.
        hilog.warn(DOMAIN, TAG, 'applyRemoteDeletions failed for %{public}s: %{public}s',
          id, String(err));
      }
    }
    return applied;
  }
}

/** Wire shape of one tombstone row. */
interface TombstonePair {
  id: string;
  deletedAt: number;
}
