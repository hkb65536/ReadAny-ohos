/**
 * Database lifecycle and the sync bookkeeping helpers every repository needs.
 *
 * Ported from ReadAny `packages/core/src/db/db-core.ts`: `initDatabase`,
 * `getDeviceId`, `nextSyncVersion`, `nextUpdatedAt`, `insertTombstone`.
 */

import type { common } from '@kit.AbilityKit';
import { DB_FILE_NAME, InkBoatError, generateId, SyncErrorKind } from 'core';
import { openDatabase, Rdb } from './Rdb';
import type { Row } from './Rdb';
import {
  CURRENT_SCHEMA_VERSION,
  META_DEVICE_ID,
  META_LAST_SYNC_AT,
  SCHEMA_MIGRATIONS,
  SCHEMA_STATEMENTS,
  type SchemaMigration,
} from './Schema';

/** `sync_metadata` key holding the schema version reached by this install. */
const META_SCHEMA_VERSION: string = 'schema_version';

export class Database {
  private readonly rdb: Rdb;
  private deviceIdCache: string = '';
  /** Table names whose existence has been confirmed this session. */
  private readonly knownTables: Set<string> = new Set<string>();

  private constructor(rdb: Rdb) {
    this.rdb = rdb;
  }

  /**
   * Open the database and bring the schema up to date.
   *
   * Safe to call more than once per process; prefer keeping one instance in the
   * ability and passing it down.
   */
  static async open(context: common.UIAbilityContext): Promise<Database> {
    const rdb: Rdb = await openDatabase(context, DB_FILE_NAME);
    const db: Database = new Database(rdb);
    await db.initializeSchema();
    return db;
  }

  /** The wrapper, for repositories that need to run their own SQL. */
  get rdbHandle(): Rdb {
    return this.rdb;
  }

  private async initializeSchema(): Promise<void> {
    for (const statement of SCHEMA_STATEMENTS) {
      await this.rdb.execute(statement);
    }

    const raw: string = await this.getMeta(META_SCHEMA_VERSION);
    const installed: number = raw.length > 0 ? Number.parseInt(raw, 10) : 0;
    if (Number.isNaN(installed)) {
      throw new InkBoatError(SyncErrorKind.DATABASE, '数据库 schema 版本字段损坏');
    }

    // Forward-only. A downgrade (installed > current) is not repaired here —
    // there is nothing safe to do about it automatically, and silently
    // "downgrading" a schema would be worse than leaving it alone.
    for (const migration of SCHEMA_MIGRATIONS) {
      if (migration.version > installed) {
        await this.applyMigration(migration);
      }
    }

    if (installed < CURRENT_SCHEMA_VERSION) {
      await this.setMeta(META_SCHEMA_VERSION, String(CURRENT_SCHEMA_VERSION));
    }
  }

  private async applyMigration(migration: SchemaMigration): Promise<void> {
    for (const statement of migration.statements) {
      await this.rdb.execute(statement);
    }
  }

  // -------------------------------------------------------------------------
  // sync_metadata
  // -------------------------------------------------------------------------

  async getMeta(key: string): Promise<string> {
    const rows: string[] = await this.rdb.select<string>(
      'SELECT value FROM sync_metadata WHERE key = ?',
      (row: Row): string => row.str('value'),
      [key],
    );
    return rows.length > 0 ? rows[0] : '';
  }

  async setMeta(key: string, value: string): Promise<void> {
    await this.rdb.execute(
      'INSERT OR REPLACE INTO sync_metadata (key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  // -------------------------------------------------------------------------
  // identity
  // -------------------------------------------------------------------------

  /**
   * Stable per-install device identifier.
   *
   * Unlike ReadAny this does not also mirror the value into a key-value store:
   * `sync_metadata` lives inside the app sandbox and is removed with the app,
   * which is exactly the lifetime a device id should have. Reinstalling gets a
   * new id, which is correct — the old id's remote files are still read, and
   * this device simply starts writing a new `device-{id}` lineage.
   */
  async getDeviceId(): Promise<string> {
    if (this.deviceIdCache.length > 0) {
      return this.deviceIdCache;
    }
    const stored: string = await this.getMeta(META_DEVICE_ID);
    if (stored.length > 0) {
      this.deviceIdCache = stored;
      return stored;
    }
    const created: string = generateId();
    await this.setMeta(META_DEVICE_ID, created);
    this.deviceIdCache = created;
    return created;
  }

  async getLastSyncAt(): Promise<number> {
    const raw: string = await this.getMeta(META_LAST_SYNC_AT);
    if (raw.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseInt(raw, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  async setLastSyncAt(timestamp: number): Promise<void> {
    await this.setMeta(META_LAST_SYNC_AT, String(timestamp));
  }

  // -------------------------------------------------------------------------
  // sync versioning and tombstones
  // -------------------------------------------------------------------------

  /** Next `sync_version` for a table. Monotonic per table, used only for ordering. */
  async nextSyncVersion(table: string): Promise<number> {
    const value: number = Number(await this.rdb.scalar(`SELECT MAX(sync_version) AS max_v FROM ${table}`));
    return (Number.isNaN(value) ? 0 : value) + 1;
  }

  /**
   * A strictly increasing `updated_at` for one row.
   *
   * `Math.max(now, current + 1)` guarantees the value advances even when a user
   * edits twice inside the same millisecond. Without the `+ 1` the second edit
   * would carry an identical timestamp and lose the last-write-wins comparison
   * on the other device.
   */
  async nextUpdatedAt(table: string, id: string): Promise<number> {
    const now: number = Date.now();
    try {
      const rows: number[] = await this.rdb.select<number>(
        `SELECT updated_at FROM ${table} WHERE id = ?`,
        (row: Row): number => row.num('updated_at'),
        [id],
      );
      const current: number = rows.length > 0 ? rows[0] : 0;
      return Math.max(now, current + 1);
    } catch (err) {
      return now;
    }
  }

  /** Record a deletion so it propagates instead of being resurrected by a peer. */
  async insertTombstone(id: string, tableName: string, bookId?: string): Promise<void> {
    const deviceId: string = await this.getDeviceId();
    await this.rdb.execute(
      'INSERT OR REPLACE INTO sync_tombstones (id, table_name, deleted_at, device_id, book_id) VALUES (?, ?, ?, ?, ?)',
      [id, tableName, Date.now(), deviceId, bookId !== undefined && bookId.length > 0 ? bookId : null],
    );
  }

  /**
   * Record a deletion that arrived from a peer, keeping the newest marker.
   *
   * The `CASE` guards make this idempotent: re-applying the same remote deletion
   * (which happens on every sync that re-reads the peer's file) must not move
   * `deleted_at` forward, or the tombstone would keep "winning" forever against
   * a local edit that legitimately resurrected the row.
   */
  async rememberRemoteTombstone(
    id: string,
    tableName: string,
    deletedAt: number,
    deviceId: string,
    bookId?: string,
  ): Promise<void> {
    await this.rdb.execute(
      `INSERT INTO sync_tombstones (id, table_name, deleted_at, device_id, book_id)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(id, table_name) DO UPDATE SET
         deleted_at = CASE
           WHEN excluded.deleted_at > sync_tombstones.deleted_at
           THEN excluded.deleted_at
           ELSE sync_tombstones.deleted_at
         END,
         device_id = CASE
           WHEN excluded.deleted_at > sync_tombstones.deleted_at
           THEN excluded.device_id
           ELSE sync_tombstones.device_id
         END,
         book_id = CASE
           WHEN excluded.deleted_at >= sync_tombstones.deleted_at
           THEN COALESCE(excluded.book_id, sync_tombstones.book_id)
           ELSE sync_tombstones.book_id
         END`,
      [id, tableName, deletedAt, deviceId, bookId !== undefined && bookId.length > 0 ? bookId : null],
    );
  }

  /** True when the table exists, checked once per session. */
  async hasTable(table: string): Promise<boolean> {
    if (this.knownTables.has(table)) {
      return true;
    }
    const columns: Set<string> = await this.rdb.tableColumns(table);
    const exists: boolean = columns.size > 0;
    if (exists) {
      this.knownTables.add(table);
    }
    return exists;
  }

  /** Column names of a table, or an empty set when it does not exist. */
  async columnsOf(table: string): Promise<Set<string>> {
    return await this.rdb.tableColumns(table);
  }

  close(): void {
    this.rdb.close();
  }
}
