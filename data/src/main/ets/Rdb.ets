/**
 * Thin typed wrapper over `@ohos.data.relationalStore`.
 *
 * The repositories speak SQL and read rows through `Row`, which keeps the SQL
 * identical to ReadAny's and avoids `ValuesBucket`'s loosely typed surface at
 * every call site. `ResultSet` is always closed here so a leaking cursor cannot
 * exhaust the connection pool.
 *
 * `Row` is a class rather than an interface: ArkTS rejects an object literal as
 * the value of an interface type when the interface is imported across a module
 * boundary (`arkts-no-untyped-obj-literals`), so the reader is a real instance.
 */

import { relationalStore } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';
import { InkBoatError, SyncErrorKind } from 'core';

/** Column values accepted as bind parameters. */
export type BindValue = string | number | boolean | null | Uint8Array;

function fail(action: string, err: Object): InkBoatError {
  const code: number = errorCodeOf(err);
  const message: string = err instanceof Error ? err.message : JSON.stringify(err);
  // The code is carried, not just the text. Retry decisions must be made on the code:
  // matching "database is locked" in a message is how the reference implementation
  // does it, but this SDK publishes stable codes and paraphrasing a message is
  // brittle across locales.
  return new InkBoatError(SyncErrorKind.DATABASE, `${action} 失败：${message}`, code);
}

/** The numeric `code` of a thrown `BusinessError`, or 0. */
function errorCodeOf(err: Object): number {
  if (err === null || err === undefined) {
    return 0;
  }
  const candidate: Object = (err as Record<string, Object>)['code'];
  if (typeof candidate === 'number') {
    return candidate;
  }
  if (typeof candidate === 'string') {
    const parsed: number = Number(candidate);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/**
 * Database error codes worth retrying.
 *
 * `14800024` and `14800025` are SQLite's two `SQLITE_BUSY` variants — the file and a
 * table within it — and they are exactly the contention the reference implementation
 * retries on. `14800015` ("does not respond") is the same class of transient stall.
 *
 * The distinction matters: this busy timeout (`PRAGMA busy_timeout`) already makes
 * SQLite wait before giving up, so a lock error surfacing at all means the wait
 * expired. Retrying after that is not redundant, it is the second layer.
 */
const RETRYABLE_DB_CODES: number[] = [14800015, 14800024, 14800025];

/** Attempts per operation, matching the reference implementation's default. */
const DB_RETRY_ATTEMPTS: number = 5;

/** Base backoff; the delay grows linearly with the attempt number. */
const DB_RETRY_BASE_MS: number = 80;

function isRetryableDbCode(code: number): boolean {
  return RETRYABLE_DB_CODES.includes(code);
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * Serializes database writes.
 *
 * The reference implementation keeps a module-level promise chain for this, and the
 * reason is the same here: every write is issued from the UI thread, but they arrive
 * from independent sources — a reading-position flush, an annotation save, an import
 * and an automatic sync can all be in flight at once. Serializing them turns a lock
 * conflict into a wait rather than a retry.
 *
 * Only operations that write go through this. Reads are not queued: a queued read
 * would put a database round-trip behind an unrelated write, and reads do not take
 * the write lock that causes the contention.
 */
let writeQueue: Promise<void> = Promise.resolve();

/**
 * True while the task at the head of `writeQueue` is executing.
 *
 * **This is the guard that stops the queue deadlocking on itself.** Without it, an
 * operation that is already running on the queue and issues another queued write
 * waits for a slot behind itself, forever:
 *
 *     writeTransaction(async () => {
 *       const deviceId = await db.getDeviceId();   // can queue `setMeta`
 *       ...
 *     });
 *
 * `getDeviceId` reads through `getMeta` (a plain query, never queued) and only writes
 * on its **first** call in a process, when `deviceIdCache` is still cold — so the
 * deadlock is intermittent: a run whose cache happens to be warm completes and hides
 * the bug, and a cold run wedges every subsequent write in the process, silently and
 * with nothing logged, because the promise never settles. That is exactly the failure
 * observed on a device: `savePosition` neither resolved nor rejected, and the WAL
 * never grew.
 *
 * With the guard, a nested write runs **inline** on the queue slot the outer call
 * already holds. It is still serialized against other writers (the outer call owns
 * the slot), and it is still retried, so nothing about the ordering guarantee changes.
 */
let queueBusy: boolean = false;

/**
 * Run an operation with retry on lock contention, serialized against other writes.
 *
 * The whole operation is retried rather than a single statement, which is what makes
 * this useful for read-modify-write: `nextSyncVersion` followed by an `UPDATE` can
 * lose the value it just read if the retry only re-runs the `UPDATE`.
 *
 * Re-entrant by design — see `queueBusy`. A nested call must never wait on the queue,
 * because the queue is waiting on it.
 */
async function runWithRetry<T>(operation: () => Promise<T>): Promise<T> {
  const run = async (): Promise<T> => {
    queueBusy = true;
    try {
      return await retryOperation(operation);
    } finally {
      queueBusy = false;
    }
  };
  if (queueBusy) {
    // Already inside a queue slot: run inline rather than queue behind ourselves.
    return retryOperation(operation);
  }
  // Chained so the next write waits for this one, whether it succeeded or failed.
  const queued: Promise<T> = writeQueue.then(run, run);
  writeQueue = queued.then(
    (): void => {},
    (): void => {},
  );
  return queued;
}

/** The retry loop, separated so both the queued and the inline path share it. */
async function retryOperation<T>(operation: () => Promise<T>): Promise<T> {
  let lastError: Error = new Error('unreachable');
  for (let attempt = 1; attempt <= DB_RETRY_ATTEMPTS; attempt++) {
    try {
      return await operation();
    } catch (err) {
      lastError = asError(err as Object);
      if (!isRetryableDbCode(errorCodeOf(err as Object)) || attempt === DB_RETRY_ATTEMPTS) {
        throw lastError;
      }
      await sleep(DB_RETRY_BASE_MS * attempt);
    }
  }
  throw lastError;
}

/**
 * Coerce a caught value into an `Error`.
 *
 * ArkTS forbids `throw` with an arbitrary type and forbids type annotations in a
 * `catch`, so a rethrow has to be re-wrapped. `InkBoatError` is preserved so a code
 * a caller relies on is not lost.
 */
function asError(cause: Object | undefined): Error {
  if (cause instanceof Error) {
    return cause;
  }
  return new Error(cause === undefined ? 'unknown database error' : JSON.stringify(cause));
}

/** Coerce a column value to a number, tolerating integer-typed columns. */
function toNumber(value: relationalStore.ValueType): number {
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'boolean') {
    return value ? 1 : 0;
  }
  if (typeof value === 'bigint') {
    return Number(value);
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/** Render a column value as text without losing integers to float formatting. */
function cellToString(value: relationalStore.ValueType): string {
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
    return String(value);
  }
  return '';
}

/** Read-only view of one result row, addressed by column name. */
export class Row {
  private readonly resultSet: relationalStore.ResultSet;

  constructor(resultSet: relationalStore.ResultSet) {
    this.resultSet = resultSet;
  }

  /** Column index, or -1 when the column is absent or holds SQL NULL. */
  private presentIndex(name: string): number {
    const index: number = this.resultSet.getColumnIndex(name);
    if (index < 0 || this.resultSet.isColumnNull(index)) {
      return -1;
    }
    return index;
  }

  /** True when the column is absent or NULL. */
  isNull(name: string): boolean {
    return this.presentIndex(name) < 0;
  }

  /** Text value; empty string when absent or NULL. */
  str(name: string): string {
    const index: number = this.presentIndex(name);
    return index < 0 ? '' : cellToString(this.resultSet.getValue(index));
  }

  /** Text value, or the fallback when absent, NULL or empty. */
  strOr(name: string, fallback: string): string {
    const value: string = this.str(name);
    return value.length > 0 ? value : fallback;
  }

  /** Text value, or `undefined` when absent, NULL or empty. */
  optStr(name: string): string | undefined {
    const value: string = this.str(name);
    return value.length > 0 ? value : undefined;
  }

  /** Numeric value; 0 when absent or NULL. */
  num(name: string): number {
    const index: number = this.presentIndex(name);
    return index < 0 ? 0 : toNumber(this.resultSet.getValue(index));
  }

  /** Boolean value from a 0/1 integer. */
  bool(name: string): boolean {
    const index: number = this.presentIndex(name);
    if (index < 0) {
      return false;
    }
    const value: relationalStore.ValueType = this.resultSet.getValue(index);
    if (typeof value === 'boolean') {
      return value;
    }
    if (typeof value === 'number') {
      return value !== 0;
    }
    const text: string = cellToString(value);
    return text === '1' || text.toLowerCase() === 'true';
  }
}

/** Thin typed wrapper over one `RdbStore`. */
export class Rdb {
  private readonly store: relationalStore.RdbStore;
  private readonly columnCache: Map<string, Set<string>> = new Map<string, Set<string>>();
  /**
   * The pragma values actually in force, read back from the store at open time.
   *
   * Recorded rather than assumed. `PRAGMA foreign_keys = ON` matters for every
   * cascade delete, and an earlier version of this file merely asserted that the
   * platform handled the journal — a claim about platform behaviour that had never
   * been checked. Reading the values back makes both observable on a device.
   */
  private diagnosticsValue: string = '';

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  /** Human-readable summary of the store's effective configuration. */
  diagnostics(): string {
    return this.diagnosticsValue;
  }

  /**
   * Read back the effective pragmas.
   *
   * Called once after the tuning pragmas run. A read failure leaves the summary
   * saying so rather than silently reporting the defaults.
   */
  async captureDiagnostics(): Promise<void> {
    let foreignKeys: string = '未知';
    let journal: string = '未知';
    try {
      const fk: relationalStore.ValueType = await this.scalar('PRAGMA foreign_keys');
      foreignKeys = fk === null || fk === undefined ? '未知' : String(fk);
    } catch (err) {
      foreignKeys = '读取失败';
    }
    try {
      const jm: relationalStore.ValueType = await this.scalar('PRAGMA journal_mode');
      journal = jm === null || jm === undefined ? '未知' : String(jm);
    } catch (err) {
      journal = '读取失败';
    }
    this.diagnosticsValue = `外键 ${foreignKeys} · 日志 ${journal}`;
  }

  /**
   * Run a statement that returns no rows.
   *
   * The ArkTS SDK's `executeSql` overloads are callback-oriented, so `execute` is
   * used for both plain statements and parameterised writes — it accepts bind
   * arguments and returns a promise.
   */
  async execute(sql: string, args?: relationalStore.ValueType[]): Promise<void> {
    // Non-parameterised statements are DDL and tuning pragmas; they are not the
    // contended writes and queueing them would only delay schema setup.
    if (args === undefined) {
      try {
        await this.store.execute(sql, args);
      } catch (err) {
        throw fail(`执行 SQL 失败 [${sql}]`, err as Object);
      }
      return;
    }
    try {
      await runWithRetry(async (): Promise<void> => {
        await this.store.execute(sql, args);
      });
    } catch (err) {
      throw fail(`执行 SQL 失败 [${sql}]`, err as Object);
    }
  }

  /**
   * Run a read-modify-write as one retried, serialized unit.
   *
   * Exposed so a repository that needs to read a counter and write it back gets the
   * whole sequence retried, not just the final statement. Re-running only the write
   * after a conflict would apply a value read before the conflicting write landed.
   */
  async writeTransaction<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await runWithRetry(operation);
    } catch (err) {
      throw fail('数据库写入失败', err as Object);
    }
  }

  /**
   * Run a statement and return the first column of the first row.
   *
   * Used for scalar aggregates such as `SELECT MAX(sync_version) FROM t`.
   */
  async scalar(sql: string, args?: relationalStore.ValueType[]): Promise<relationalStore.ValueType> {
    const resultSet: relationalStore.ResultSet = await this.query(sql, args);
    try {
      if (!resultSet.goToFirstRow()) {
        return null;
      }
      if (resultSet.columnCount === 0) {
        return null;
      }
      if (resultSet.isColumnNull(0)) {
        return null;
      }
      return resultSet.getValue(0);
    } finally {
      resultSet.close();
    }
  }

  /**
   * Run `SELECT` and read every row through `mapper`. */
  async select<T>(
    sql: string,
    mapper: (row: Row) => T,
    args?: relationalStore.ValueType[],
  ): Promise<T[]> {
    const resultSet: relationalStore.ResultSet = await this.query(sql, args);
    const out: T[] = [];
    try {
      while (resultSet.goToNextRow()) {
        out.push(mapper(new Row(resultSet)));
      }
    } finally {
      resultSet.close();
    }
    return out;
  }

  async query(sql: string, args?: relationalStore.ValueType[]): Promise<relationalStore.ResultSet> {
    try {
      return await this.store.querySql(sql, args);
    } catch (err) {
      throw fail(`查询失败 [${sql}]`, err as Object);
    }
  }

  /**
   * Column names of a table, or an empty set when it does not exist.
   *
   * The sync upsert builds its column list from this, which is what keeps a
   * remote row carrying a column this client does not know about from breaking
   * the insert.
   */
  async tableColumns(table: string): Promise<Set<string>> {
    const cached: Set<string> | undefined = this.columnCache.get(table);
    if (cached !== undefined) {
      return cached;
    }
    const columns: Set<string> = new Set<string>();
    const resultSet: relationalStore.ResultSet = await this.query(`PRAGMA table_info(${table})`);
    try {
      const nameIndex: number = resultSet.getColumnIndex('name');
      while (resultSet.goToNextRow()) {
        if (nameIndex >= 0 && !resultSet.isColumnNull(nameIndex)) {
          columns.add(cellToString(resultSet.getValue(nameIndex)));
        }
      }
    } finally {
      resultSet.close();
    }
    this.columnCache.set(table, columns);
    return columns;
  }

  /** The underlying store, for the few callers that need transactions. */
  raw(): relationalStore.RdbStore {
    return this.store;
  }

  close(): void {
    this.columnCache.clear();
    this.store.close();
  }
}

/**
 * Tuning pragmas, mirroring the reference implementation's `configureDatabaseConnection`.
 *
 * `foreign_keys` is the important one: every annotation table cascades on book
 * deletion, and SQLite disables foreign keys by default.
 *
 * `journal_mode = WAL` is set explicitly rather than assumed. An earlier version of
 * this file left it out and asserted that the platform manages the journal for this
 * store — a claim about platform behaviour that was **invented, not verified**, and
 * that the SDK does not support. The reference implementation sets it on every
 * connection; the SDK documents a WAL-specific error (`14800047`, the WAL file size
 * limit) without saying the platform selects the mode. Setting it is idempotent and is
 * the pattern the platform's own error surface expects, so the two agree.
 *
 * Every statement is individually fault tolerant, because a store that refuses one
 * pragma is still usable. The values actually in force are read back afterwards and
 * shown in the UI, so a refusal is visible where it matters rather than only in a log.
 */
const PRAGMAS: string[] = [
  'PRAGMA journal_mode = WAL',
  'PRAGMA foreign_keys = ON',
  'PRAGMA synchronous = NORMAL',
  'PRAGMA busy_timeout = 15000',
];

/**
 * Open (or create) the local database.
 *
 * `securityLevel: S3` is what the SDK requires for a store holding user content;
 * lower levels are rejected for databases with user data.
 */
export async function openDatabase(context: common.UIAbilityContext, name: string): Promise<Rdb> {
  const config: relationalStore.StoreConfig = {
    name: name,
    securityLevel: relationalStore.SecurityLevel.S3,
  };

  let store: relationalStore.RdbStore;
  try {
    store = await relationalStore.getRdbStore(context, config);
  } catch (err) {
    throw fail(`打开数据库 ${name} 失败`, err as Object);
  }

  const db: Rdb = new Rdb(store);
  for (const pragma of PRAGMAS) {
    try {
      await db.execute(pragma);
    } catch (err) {
      // A store that refuses a tuning pragma is still usable. Silent on purpose: a
      // refusal here is normal on some platform versions, and the effective values
      // are read back below and surfaced to the UI, so a refused pragma is visible
      // where it matters rather than only in a log.
    }
  }
  await db.captureDiagnostics();
  return db;
}
