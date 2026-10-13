/**
 * ReadAny v1 WebDAV sync protocol — the per-device snapshot engine.
 *
 * Ported from ReadAny **v1.3.6** `packages/core/src/sync/simple-sync.ts`
 * (`collectChanges`, `applyChanges`, `saveDeviceSnapshot`, `loadDeviceSyncIndex`,
 * `listRemoteDeviceFiles`, `runSimpleSync`), read at the tag and not at `HEAD` —
 * `HEAD` is `v1.3.6-77` and carries an unreleased rewrite of this file.
 *
 * ## Why this exists next to `SyncEngine`
 *
 * `SyncEngine` speaks the *per-book* protocol (`schemaVersion: 2`): one
 * `/readany/sync/index.json` holding per-book markers, plus one file per book
 * under `/readany/sync/books/`. The user's released desktop client at v1.3.6
 * speaks a **different** protocol on the **same paths**: one full snapshot per
 * device at `/readany/sync/device-{id}.json`, discovered through a
 * `{version: 1, updatedAt, devices}` index at `/readany/sync/index.json`, with
 * rows merged row-by-row on a per-table timestamp column.
 *
 * Both exist in this client because the formats do not share a version field,
 * the merge rules differ (per-book marker max versus row-level last-writer-wins
 * over raw SQLite rows), and confusing them is destructive in both directions:
 * publishing a v2 index over a v1 one hides every device snapshot, and applying
 * a v1 snapshot with v2 rules would treat a peer's `deletedIds` list as an
 * overlay rather than the destructive instruction it is.
 *
 * ## The wire format
 *
 *     /readany/sync/index.json
 *     { version: 1, updatedAt: <ms>, devices: { <deviceId>: { path, timestamp } } }
 *
 *     /readany/sync/device-<id>.json
 *     { deviceId, timestamp, since,
 *       tables: { <table>: { records: [...], deletedIds: [...],
 *                            deletedTimestamps?: { <id>: <ms> } } } }
 *
 * One `PUT` of `JSON.stringify(payload)` as `application/json`. Not compressed,
 * not chunked. Rows are raw `SELECT *` results: raw SQLite column names, native
 * JSON types, nulls preserved. A table appears only when it has records or
 * tombstones.
 *
 * ## The three rules this file must never break
 *
 * 1. **A row absent from a snapshot is not a deletion.** Nothing here infers a
 *    deletion from local absence; only an explicit `deletedIds` entry deletes.
 * 2. **`deletedIds` is never emitted without a matching real millisecond
 *    `deletedTimestamps` entry.** `collectTableChanges` drops an id whose
 *    tombstone has no positive timestamp rather than publishing it.
 * 3. **A non-empty `deletedIds` is never emitted alongside an empty or absent
 *    `deletedTimestamps`.** Enforced by rule 2 at the only place tombstones are
 *    collected, re-checked at serialization, and re-checked again on the receive
 *    side, where a violation is refused rather than acted on.
 *
 * The reason is on the receiving side: v1.3.6's only guard is
 * `localTimestamp > deletedAt`, and that guard is **skipped entirely when
 * `deletedAt <= 0`**. A peer that emits tombstones without timestamps therefore
 * makes every other device hard-delete those rows with no comparison at all —
 * and for `books` that `DELETE` cascades through `ON DELETE CASCADE` and
 * silently destroys the book's highlights, notes, bookmarks, `book_tags` and
 * `reading_sessions`, writing no tombstones of its own.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InkBoatError, jsonReader, SyncErrorKind } from 'core';
import type { FieldReader } from 'core';
// `JsonReadOutcome` is an enum, so it is a value and cannot travel in an
// `import type` list.
import {
  isPlausibleTombstone,
  JsonReadOutcome,
  localRecordState,
  normalizeDeletedAt,
  readJsonDocument,
  resolveRemotePath,
  shouldApplyRemoteRecord,
  shouldApplyTombstone,
  utf8Decode,
} from 'sync';
import type { LocalRecordState, WebDavClient, WebDavConfig } from 'sync';
import { defaultBinaryOptions } from './BinarySync';
import type { BinarySyncOptions, V1FileCounts, V1FileRunner } from './BinarySync';
import {
  canonicalBookCoverPath,
  canonicalBookFilePath,
  bookFilePathForExtension,
  isCanonicalCoverPath,
  isConvertedSourceFormat,
  isCustomCoverPath,
  resolveBookExtension,
} from './V1BookPaths';
import type { Database } from './Database';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatSyncV1';

/** The only index version this engine reads or writes. */
export const V1_INDEX_VERSION: number = 1;

/** Remote directory holding the index and every device snapshot. */
export const V1_SYNC_DIR: string = '/readany/sync';
/** Remote path of the v1 discovery index. */
export const V1_INDEX_PATH: string = '/readany/sync/index.json';

/** Build the remote path of one device's snapshot. */
export function v1DevicePath(deviceId: string): string {
  return `${V1_SYNC_DIR}/device-${deviceId}.json`;
}

/** File-name prefix and suffix of a device snapshot, used when listing. */
const DEVICE_FILE_PREFIX: string = 'device-';
const DEVICE_FILE_SUFFIX: string = '.json';

/** Re-push a full snapshot at least this often even when nothing changed. */
const SNAPSHOT_MAX_AGE_MS: number = 5 * 60 * 1000;

// ---------------------------------------------------------------------------
// Table configuration
// ---------------------------------------------------------------------------

/**
 * One synced table: its primary key, its last-write-wins column, and any column
 * that must never leave or enter this device.
 *
 * `excludeColumns` exists only for `books`, for `is_vectorized` and
 * `vectorize_progress`. Those two belong to the RAG feature, whose chunks and
 * embeddings live in a *local* database (`readany_local.db`), so the flags are
 * per-device facts rather than shared state: writing a peer's `1` here would
 * claim this device had indexed a book it has not, and sending this device's `1`
 * would claim the same to every peer.
 */
export interface V1TableConfig {
  name: string;
  pk: string;
  timestampCol: string;
  excludeColumns: string[];
}

/**
 * Every shared table this client has, in the reference implementation's fixed
 * apply order: parents before children, so a child row never arrives before the
 * parent it references.
 *
 * **Scope note, stated deliberately.** ReadAny v1.3.6 syncs eleven tables. This
 * client's schema defines five of them: `book_groups`, `books`, `highlights`,
 * `notes`, `bookmarks`. The other six (`threads`, `messages`, `skills`, `tags`,
 * `book_tags`, `reading_sessions`) belong to features this client does not
 * implement and has no table for.
 *
 * They are left **out of the payload entirely**, not emitted as empty
 * changesets. That distinction is the whole safety argument: an emitted
 * `{records: [], deletedIds: []}` — or worse, a `deletedIds` list built from a
 * table that does not exist here — would tell every peer that this device knows
 * those rows are gone. Omitting the key says only "this device has nothing to
 * say", which is the truth. The cost is a gap rather than a corruption: those
 * tables simply do not travel through this client.
 */
export const V1_SYNC_TABLES: V1TableConfig[] = [
  { name: 'book_groups', pk: 'id', timestampCol: 'updated_at', excludeColumns: [] },
  {
    name: 'books',
    pk: 'id',
    timestampCol: 'updated_at',
    excludeColumns: ['is_vectorized', 'vectorize_progress'],
  },
  { name: 'highlights', pk: 'id', timestampCol: 'updated_at', excludeColumns: [] },
  { name: 'notes', pk: 'id', timestampCol: 'updated_at', excludeColumns: [] },
  { name: 'bookmarks', pk: 'id', timestampCol: 'updated_at', excludeColumns: [] },
];

/** Column config for a table, or `undefined` when it is not a synced table. */
export function v1TableConfig(table: string): V1TableConfig | undefined {
  for (const config of V1_SYNC_TABLES) {
    if (config.name === table) {
      return config;
    }
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

/**
 * One row as it travels: raw `SELECT *` column names, JSON-native values.
 *
 * `null` is a first-class member, not an omission, and the difference is
 * load-bearing. The protocol says a row travels with its native JSON types and
 * its nulls preserved, and the receiving upsert only writes the columns that are
 * **present** in the object it is handed — so an omitted column means "leave mine
 * alone" while a column set to `null` means "mine is empty". `cover_url` is the
 * case that depends on the distinction; see `localizeSyncedBookRecord`.
 *
 * Plain `Record<string, Object>` cannot express this, because ArkTS does not allow
 * `null` to be assigned to `Object`. The row container was therefore the wrong
 * type, not the `null`.
 */
export type WireRow = Record<string, Object | null>;

/** One table's slice of a device snapshot. */
export interface TableChangeset {
  records: WireRow[];
  deletedIds: string[];
  /**
   * Id → deletion time in ms, for every id in `deletedIds`.
   *
   * Optional in the *type* because a v1.3.6 peer's payload is what it is, and
   * the reference's own writer makes the field optional. The writer in this file
   * always sets it whenever `deletedIds` is non-empty; see `collectTableChanges`.
   */
  deletedTimestamps?: Record<string, number>;
}

/** One device's full snapshot, as stored at `/readany/sync/device-<id>.json`. */
export interface DeviceSyncPayload {
  deviceId: string;
  /** Unix ms of when this payload was generated. */
  timestamp: number;
  /** The last-sync timestamp this device used to collect the changes. */
  since: number;
  tables: Record<string, TableChangeset>;
}

/** One device's entry in the discovery index. */
export interface DeviceIndexEntry {
  path: string;
  timestamp: number;
}

/** `/readany/sync/index.json`, the v1 discovery index. */
export interface DeviceSyncIndex {
  version: number;
  updatedAt: number;
  devices: Record<string, DeviceIndexEntry>;
}

/** One snapshot candidate found on the server. */
export interface V1RemoteDevice {
  deviceId: string;
  /** Logical protocol path (`/readany/sync/device-<id>.json`). */
  path: string;
  /** True when the entry came from the index rather than from a directory listing. */
  fromIndex: boolean;
}

/**
 * How a remote `index.json` was classified.
 *
 * Ported from the reference's `loadDeviceSyncIndex`, which returns `null` unless
 * `version === 1` **and** `devices` is an object — and extended with the names
 * `sync/SyncFile.ets` already uses for the other documents that share this path.
 */
export enum V1IndexKind {
  /** No document: a 404, or an empty body. The normal first run. */
  ABSENT = 'absent',
  /** `{version: 1, updatedAt, devices}` — the format this engine writes. */
  INDEX_V1 = 'index-v1',
  /** Version 1 but a `devices` value this engine cannot read. Refused. */
  INDEX_V1_MALFORMED = 'index-v1-malformed',
  /** A `schemaVersion: 2` per-book index, written by `SyncEngine`. Refused. */
  PER_BOOK_V2 = 'per-book-v2',
  /** A `{version: N, devices}` index from a client that is not v1. Refused. */
  INDEX_OTHER_VERSION = 'index-other-version',
  /** A `DeviceSyncPayload` body sitting at the index path. Refused. */
  DEVICE_PAYLOAD = 'device-payload',
  /** A body arrived and is not a JSON object. Refused. */
  UNPARSEABLE = 'unparseable',
  /** Valid JSON, object, and not a shape this engine can name. Refused. */
  UNKNOWN = 'unknown',
}

/** Outcome of loading the remote index. */
export interface V1IndexLoad {
  kind: V1IndexKind;
  /** Entries by device id; empty unless `kind === INDEX_V1`. */
  devices: Map<string, DeviceIndexEntry>;
  /** The parsed document, for a caller that wants to report its shape. */
  record: Record<string, Object> | undefined;
}

/** Counters for one pass. */
export interface V1SyncCounts {
  applied: number;
  skipped: number;
  /** Deletions refused because the payload did not justify them. */
  refusedDeletions: number;
  /** Tables skipped because this client has no such table. */
  skippedTables: number;
  /** Rows skipped because a column was missing or a value was not bindable. */
  skippedRows: number;
  /** Tables written into the snapshot this device uploaded. */
  tablesUploaded: number;
}

/** Result of one pass. */
export interface V1SyncResult {
  success: boolean;
  counts: V1SyncCounts;
  /** Device ids whose snapshots were applied. */
  appliedDevices: string[];
  /** True when this device's own snapshot was written. */
  uploaded: boolean;
  /** Empty on success. */
  error: string;
  /**
   * What the file phase moved.
   *
   * All zero when no file runner was supplied, which is a real state and not a failure:
   * the engine is still usable metadata-only. The counters are reported rather than
   * inferred, so a "0 files" line means "nothing moved", never "the files failed".
   */
  files: V1FileSyncCounts;
}

/** Live progress line. */
export interface V1Progress {
  message: string;
  completed: number;
  total: number;
}

/** Progress callback. */
export type V1ProgressFn = (progress: V1Progress) => void;

/** File counters for one pass, mirrored onto the result so the summary can state them. */
export interface V1FileSyncCounts {
  filesUploaded: number;
  filesDownloaded: number;
  filesFailed: number;
  /** True when the manifest write was abandoned because it could not be read. */
  manifestRefused: boolean;
  /** The refusal text, empty unless `manifestRefused`. */
  manifestError: string;
  /** Why the file phase stopped early, empty when it ran to the end. */
  phaseError: string;
  /**
   * The first distinct reason a transfer failed, empty when none did.
   *
   * Mirrored from `V1FileCounts` so the summary can name a cause. A count without one is
   * the state that was reported as "失败 18" with nothing else anywhere — see
   * `V1FileCounts.firstFailure` for why the first is the one kept.
   */
  firstFailure: string;
}

export function emptyV1FileSyncCounts(): V1FileSyncCounts {
  return {
    filesUploaded: 0,
    filesDownloaded: 0,
    filesFailed: 0,
    manifestRefused: false,
    manifestError: '',
    phaseError: '',
    firstFailure: '',
  };
}

/** Options for one pass. */
export interface V1SyncOptions {
  /** Apply remote snapshots but never write this device's own. */
  receiveOnly: boolean;
  /** Apply every remote record, bypassing the timestamp comparison. */
  forceApply: boolean;
  /** Files: send every local book file even when the server already has one. */
  forceUploadAll: boolean;
  /** Files: fetch every remote book file even when a local copy exists. */
  forceDownloadAll: boolean;
  /**
   * Files: fetch remote book files at all.
   *
   * `false` for a normal pass, matching the reference (`sync-files.ts:372`): a normal v1
   * sync must not pull the library over whatever network the phone happens to be on. That
   * is a data-usage contract the user is entitled to, not an optimisation.
   */
  downloadRemoteBooks: boolean;
  /** Files: skip every upload, for the restore-from-server direction. */
  disableUploads: boolean;
}

export function defaultV1SyncOptions(): V1SyncOptions {
  return {
    receiveOnly: false,
    forceApply: false,
    forceUploadAll: false,
    forceDownloadAll: false,
    downloadRemoteBooks: false,
    disableUploads: false,
  };
}

export function emptyV1SyncCounts(): V1SyncCounts {
  return {
    applied: 0,
    skipped: 0,
    refusedDeletions: 0,
    skippedTables: 0,
    skippedRows: 0,
    tablesUploaded: 0,
  };
}

// ---------------------------------------------------------------------------
// Small value helpers
// ---------------------------------------------------------------------------

/** Coerce a wire value to a number, or `fallback` when it is not numeric. */
function numberCell(value: Object | null | undefined, fallback: number): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'number') {
    return Number.isNaN(value) ? fallback : value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

/** A record cell as a plain object, or `undefined` when it is not one. */
function objectCell(value: Object | null | undefined): WireRow | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as WireRow;
}

/** True for a JSON object that is a map, not an array or a scalar. */
function isPlainObject(value: Object | null | undefined): boolean {
  return value !== undefined && value !== null
    && typeof value === 'object' && !Array.isArray(value);
}

/** The primary key of a wire record as a string, or an empty string. */
function pkOf(record: WireRow, pk: string): string {
  const value: Object | null | undefined = record[pk];
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  return '';
}

/**
 * The field names of a record, for a diagnostic line.
 *
 * `Object.keys()` is used rather than `Object.entries()`, which ArkTS restricts.
 * The parameter accepts both a document (`Record<string, Object>`) and a wire row,
 * which is why it is the wider of the two.
 */
function recordShapeOf(record: Record<string, Object | null>): string {
  const keys: string[] = Object.keys(record);
  return keys.length > 0 ? keys.join(', ') : '(no fields)';
}

/** First eight characters of an id, for a log line. */
function shortId(id: string): string {
  return id.length > 8 ? id.substring(0, 8) : id;
}

/** The two fields of a directory listing this engine uses. */
interface RemoteListing {
  name: string;
  isCollection: boolean;
}

/** A short name for a `relationalStore` cell value that JSON cannot carry. */
function nonJsonKindName(value: Object): string {
  if (typeof value === 'bigint') {
    return 'bigint';
  }
  if (typeof value === 'number') {
    return 'non-finite number';
  }
  if (Array.isArray(value)) {
    return 'array';
  }
  return 'binary or asset';
}

/**
 * Coerce a database cell into a JSON-representable value.
 *
 * The path is deliberately *not* a cast: the value is inspected and only the
 * native JSON kinds are let through. The input type is the widest thing
 * `relationalStore` hands back — `getValue` returns `ValueType`, which includes
 * `null`, `bigint`, `Uint8Array`, `Asset`, `Assets` and `Float32Array` — and only
 * the three kinds `JSON.stringify` round-trips as themselves come out. `null` and
 * `undefined` also come out as `undefined`: SQL NULL is the caller's business (it
 * is written as JSON `null`), and "not a value" is what the caller means here.
 */
function columnValue(value: Object | null | undefined): string | number | boolean | undefined {
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  return undefined;
}

/**
 * Coerce a database cell into a wire value.
 *
 * Only the native JSON kinds pass through; anything else becomes `undefined`, the
 * caller then omits the column, and the receiver's own value is left in place.
 * That is a deliberate, logged skip rather than a coercion:
 *
 *  - an `Asset`, an `Assets` bundle, a `Float32Array` or a `Uint8Array` cannot be
 *    represented in JSON at all, and stringifying one would publish a shape no
 *    other client can read;
 *  - a `bigint` is a kind JSON has no syntax for, and `JSON.stringify` throws on it;
 *  - `NaN` and `Infinity` are *numbers* that JSON nevertheless cannot carry —
 *    `JSON.stringify` silently turns both into `null`, which on the receiving side
 *    means "this cell is empty" and would blank a peer's value. Dropping the
 *    column instead leaves the peer's value alone, which is the fail-safe
 *    direction.
 *
 * SQL NULL is handled by the caller, because a `null` return is not expressible in
 * this return type.
 */
function columnCell(value: Object | null | undefined): string | number | boolean | undefined {
  if (typeof value === 'string' || typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    if (Number.isFinite(value)) {
      return value;
    }
    hilog.warn(DOMAIN, TAG,
      'omitting a %{public}s cell from the snapshot: JSON cannot carry it, and serializing it '
      + 'would publish null and blank the value on every peer',
      nonJsonKindName(value));
    return undefined;
  }
  if (value !== undefined && value !== null) {
    hilog.warn(DOMAIN, TAG,
      'omitting a %{public}s cell from the snapshot: it is not representable in JSON',
      nonJsonKindName(value));
  }
  return undefined;
}

/**
 * The default clock.
 *
 * A module-level function rather than an inline arrow default in the constructor:
 * ArkTS cannot parse `clock ?? (): number => Date.now()` as a parameter default.
 */
function systemClock(): number {
  return Date.now();
}

// ---------------------------------------------------------------------------
// Index classification
// ---------------------------------------------------------------------------

/**
 * Classify a parsed remote index document.
 *
 * The order matters. A `schemaVersion: 2` per-book index is named first because
 * it shares the path; a version-1 document with an unreadable `devices` is
 * separated from a version-1 document that is merely empty, because the first
 * must block a write and the second must not — an absent index is the normal
 * first run, and refusing it would make a first sync impossible.
 *
 * Note the deliberate difference from `SyncFile.isLegacyIndex`, which accepts
 * **any** numeric `version`. That laxity is right for a refusal guard, where
 * being generous can only change which message the user sees. It is wrong here,
 * where the answer decides whether this engine may write: a v2 per-book index
 * carries no `version` field at all, and a peer's `{version: 2, devices: {…}}`
 * would otherwise classify as a v1 index and be overwritten with a v1 one.
 */
export function classifyV1Index(record: Record<string, Object> | undefined): V1IndexKind {
  if (record === undefined) {
    return V1IndexKind.ABSENT;
  }
  if (record['schemaVersion'] === 2 && isPlainObject(record['books'])
    && isPlainObject(record['threads'])) {
    return V1IndexKind.PER_BOOK_V2;
  }
  if (typeof record['deviceId'] === 'string' && isPlainObject(record['tables'])) {
    return V1IndexKind.DEVICE_PAYLOAD;
  }
  if (record['version'] === undefined || record['version'] === null) {
    return V1IndexKind.UNKNOWN;
  }
  if (record['version'] !== V1_INDEX_VERSION) {
    return V1IndexKind.INDEX_OTHER_VERSION;
  }
  if (!isPlainObject(record['devices'])) {
    return V1IndexKind.INDEX_V1_MALFORMED;
  }
  return V1IndexKind.INDEX_V1;
}

/**
 * Read the device entries of a v1 index.
 *
 * An entry whose shape is not `{path: string, timestamp: number}` is dropped
 * rather than guessed at; the directory listing is still consulted, so a dropped
 * entry costs discovery order, never a device. A missing `timestamp` reads as 0
 * because the reference never uses it for merging — it is a convenience field,
 * and the payload's own `timestamp` is the authority.
 */
export function readDeviceEntries(
  record: Record<string, Object> | undefined,
): Map<string, DeviceIndexEntry> {
  const out: Map<string, DeviceIndexEntry> = new Map<string, DeviceIndexEntry>();
  if (record === undefined) {
    return out;
  }
  const devices: WireRow | undefined = objectCell(record['devices']);
  if (devices === undefined) {
    return out;
  }
  for (const deviceId of Object.keys(devices)) {
    const entry: WireRow | undefined = objectCell(devices[deviceId]);
    if (entry === undefined) {
      continue;
    }
    const path: Object | null | undefined = entry['path'];
    if (typeof path !== 'string' || path.length === 0) {
      continue;
    }
    out.set(deviceId, { path: path, timestamp: numberCell(entry['timestamp'], 0) });
  }
  return out;
}

/** True when this kind of index may be read *and* replaced. */
export function isWritableV1IndexKind(kind: V1IndexKind): boolean {
  return kind === V1IndexKind.ABSENT || kind === V1IndexKind.INDEX_V1;
}

/** A message naming what was found, for a refusal to carry to the user. */
export function indexRefusalMessage(
  kind: V1IndexKind,
  record: Record<string, Object> | undefined,
): string {
  const shape: string = record === undefined ? '(no fields)' : recordShapeOf(record);
  if (kind === V1IndexKind.PER_BOOK_V2) {
    return '远端索引已是新版每书格式（schemaVersion 2）。本客户端不会用 v1 每设备快照覆盖它，'
      + '否则会隐藏索引里已有的全部书籍。';
  }
  if (kind === V1IndexKind.DEVICE_PAYLOAD) {
    return `远端 index.json 的位置上是一份设备快照（字段：${shape}）。`
      + '覆盖它会丢掉它记录的全部数据，本客户端拒绝写入。';
  }
  if (kind === V1IndexKind.INDEX_OTHER_VERSION) {
    return `远端索引版本不是 1（字段：${shape}）。本客户端只认识 v1 每设备快照索引，拒绝覆盖未知版本。`;
  }
  if (kind === V1IndexKind.INDEX_V1_MALFORMED) {
    return `远端索引声明版本 1，但 devices 不是可读的设备表（字段：${shape}）。`
      + '无法确认它记录了什么，本客户端拒绝覆盖。';
  }
  if (kind === V1IndexKind.UNPARSEABLE) {
    return '远端 index.json 存在但不是 JSON 对象（可能被代理或网盘改写）。'
      + '本客户端拒绝覆盖无法解析的文件。';
  }
  return `远端 index.json 的形状无法识别（字段：${shape}）。本客户端拒绝覆盖无法识别的文件。`;
}

// ---------------------------------------------------------------------------
// Payload validation
// ---------------------------------------------------------------------------

/** The unjustified deletions found in one changeset. */
export interface ChangesetViolation {
  table: string;
  /** Ids whose deletion the payload did not justify. */
  unjustified: string[];
  /** Empty when the changeset is clean. */
  message: string;
}

/**
 * Ids in `deletedIds` whose deletion the payload does not justify.
 *
 * A deletion is unjustified when there is no `deletedTimestamps` map, no entry
 * for that id, or an entry that is not a positive finite number.
 *
 * The caller refuses exactly those ids and applies everything else. That is the
 * "fail safe, do not propagate the damage" behaviour: a payload that violates
 * the contract loses its unjustified deletions, and the rest of it — records,
 * well-formed tombstones — is still merged. Refusing the whole payload is the
 * other defensible choice, but it would let one bad id from one peer block all
 * of that peer's data indefinitely, and the missing information is precisely
 * "when did this happen", which cannot be invented.
 */
export function unjustifiedDeletions(changeset: TableChangeset, table: string): ChangesetViolation {
  const unjustified: string[] = [];
  for (const rawId of changeset.deletedIds) {
    const id: string = typeof rawId === 'string' ? rawId : String(rawId);
    const timestamps: Record<string, number> | undefined = changeset.deletedTimestamps;
    if (timestamps === undefined || timestamps === null) {
      unjustified.push(id);
      continue;
    }
    const value: number | undefined = timestamps[id];
    if (value === undefined || value === null || !Number.isFinite(value) || value <= 0) {
      unjustified.push(id);
    }
  }
  const violation: ChangesetViolation = {
    table: table,
    unjustified: unjustified,
    message: '',
  };
  if (unjustified.length > 0) {
    violation.message = `${table}: ${unjustified.length} 条删除缺少有效的 deletedTimestamps`
      + `（对端违反协议，已拒绝这些删除：${shortId(unjustified[0])}${unjustified.length > 1 ? '…' : ''}）`;
  }
  return violation;
}

/** A parsed, structurally validated snapshot. */
export interface ParsedDeviceSnapshot {
  deviceId: string;
  timestamp: number;
  since: number;
  /** Changesets by table. */
  tables: Map<string, TableChangeset>;
  /** Table keys present in the document that are not shaped like a changeset. */
  malformedTables: string[];
}

/** Fields of one changeset, read defensively. */
interface RawChangeset {
  records: WireRow[];
  deletedIds: string[];
  deletedTimestamps: Record<string, number> | undefined;
}

/** Read one table's changeset, tolerating every wrong type in it. */
function readRawChangeset(value: Object | null | undefined): RawChangeset | undefined {
  const record: WireRow | undefined = objectCell(value);
  if (record === undefined) {
    return undefined;
  }
  const records: WireRow[] = [];
  const recordsRaw: Object | null | undefined = record['records'];
  if (Array.isArray(recordsRaw)) {
    for (const item of recordsRaw as Object[]) {
      const row: WireRow | undefined = objectCell(item);
      if (row !== undefined) {
        records.push(row);
      }
    }
  }
  const deletedIds: string[] = [];
  const idsRaw: Object | null | undefined = record['deletedIds'];
  if (Array.isArray(idsRaw)) {
    for (const item of idsRaw as Object[]) {
      if (typeof item === 'string') {
        deletedIds.push(item);
      } else if (typeof item === 'number') {
        deletedIds.push(String(item));
      }
    }
  }
  let deletedTimestamps: Record<string, number> | undefined = undefined;
  const stampsRaw: WireRow | undefined = objectCell(record['deletedTimestamps']);
  if (stampsRaw !== undefined) {
    deletedTimestamps = {};
    for (const id of Object.keys(stampsRaw)) {
      const stamp: Object | null | undefined = stampsRaw[id];
      if (typeof stamp === 'number' && Number.isFinite(stamp)) {
        deletedTimestamps[id] = stamp;
      }
    }
  }
  return { records: records, deletedIds: deletedIds, deletedTimestamps: deletedTimestamps };
}

/**
 * Parse a snapshot document.
 *
 * Returns `undefined` only when the document is not a device snapshot at all.
 * Everything inside it is optional by construction: a table whose value is a
 * string, a `deletedIds` that is an object rather than an array, a missing
 * `tables` — all tolerated and contributing nothing, which is the treatment the
 * reference gives them (`payload.tables[table]` absent → `continue`). Nothing
 * here invents data.
 */
export function parseDeviceSnapshot(
  record: Record<string, Object> | undefined,
): ParsedDeviceSnapshot | undefined {
  if (record === undefined) {
    return undefined;
  }
  const tablesRaw: WireRow | undefined = objectCell(record['tables']);
  if (tablesRaw === undefined) {
    return undefined;
  }
  const tables: Map<string, TableChangeset> = new Map<string, TableChangeset>();
  const malformed: string[] = [];
  for (const table of Object.keys(tablesRaw)) {
    const raw: RawChangeset | undefined = readRawChangeset(tablesRaw[table]);
    if (raw === undefined) {
      malformed.push(table);
      continue;
    }
    const changeset: TableChangeset = {
      records: raw.records,
      deletedIds: raw.deletedIds,
      deletedTimestamps: raw.deletedTimestamps,
    };
    tables.set(table, changeset);
  }
  const deviceId: Object | undefined = record['deviceId'];
  const snapshot: ParsedDeviceSnapshot = {
    deviceId: typeof deviceId === 'string' ? deviceId : '',
    timestamp: numberCell(record['timestamp'], 0),
    since: numberCell(record['since'], 0),
    tables: tables,
    malformedTables: malformed,
  };
  return snapshot;
}

// ---------------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------------

/** The local counterpart of one row, as read before the merge. */
export interface V1LocalState {
  /** `max(row[timestampCol], tombstone.deleted_at)`. */
  timestamp: number;
  /** The row's own `deleted_at`, or `null`. */
  deletedAt: number | null;
  /** `books.cover_url`, read only for the custom-cover exception. */
  coverUrl: string;
}

/**
 * Local read + write surface.
 *
 * A port rather than direct SQL so the merge rules — which are the part that can
 * destroy data — are separable from the database and can be re-derived from the
 * source by an audit without a device. `RdbRecordWriter` is the real one.
 */
export interface V1RecordWriter {
  /** Columns the local table actually has; a remote column outside this is dropped. */
  columnsOf(table: string): Promise<Set<string>>;
  /** Read the local state of the given ids in one batch. */
  loadStates(table: string, pk: string, timestampCol: string, ids: string[]): Promise<Map<string, V1LocalState>>;
  /** Write one whole row, upserting on the primary key. */
  upsert(table: string, pk: string, record: WireRow): Promise<void>;
  /** Delete one row by primary key. */
  remove(table: string, pk: string, id: string): Promise<void>;
  /** Remember an incoming deletion so it keeps propagating. */
  rememberTombstone(table: string, id: string, deletedAt: number, deviceId: string): Promise<void>;
}

/** A value that can be bound into a statement, or `undefined` when it cannot. */
type Bindable = string | number | boolean | null | Uint8Array;

/**
 * Coerce a raw column value into a bindable JSON scalar, or `undefined`.
 *
 * `null` is returned as `null`, not skipped: the caller turns it into a bound SQL
 * NULL, which is how a peer clears a column. Anything else non-scalar is stored as
 * JSON text.
 */
function bindableValue(value: Object | null | undefined): Bindable | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (value === null) {
    return null;
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  // JSON columns (`tags`, `subjects`, `reviews`, `citations`…) hold text. A peer
  // that sent a real array or object is asking for the value its own `SELECT *`
  // would have produced — which for those columns is the JSON text. Nothing else
  // in the synced schema can hold a nested value: a BLOB cannot arrive through
  // JSON at all, and a `Uint8Array` here would be a value JSON.parse cannot make.
  if (Array.isArray(value) || typeof value === 'object') {
    return JSON.stringify(value);
  }
  return undefined;
}

/** True when at least one column of `record` holds a bindable value. */
function hasBindableColumn(record: WireRow): boolean {
  for (const key of Object.keys(record)) {
    if (bindableValue(record[key]) !== undefined) {
      return true;
    }
  }
  return false;
}

/**
 * The real record writer: the app's database behind the `V1RecordWriter` port.
 *
 * This is where the local `INSERT … ON CONFLICT(pk) DO UPDATE SET col =
 * excluded.col` is built. Every column **present in the incoming object** is
 * written, including columns set to `null`; a column absent from the object is
 * left untouched. That asymmetry is load-bearing: `deleted_at` arriving as an
 * explicit `null` must clear a local tombstone, while a peer that simply does
 * not carry a column this client added must not blank it.
 */
export class RdbRecordWriter implements V1RecordWriter {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  columnsOf(table: string): Promise<Set<string>> {
    return this.db.columnsOf(table);
  }

  async loadStates(
    table: string,
    pk: string,
    timestampCol: string,
    ids: string[],
  ): Promise<Map<string, V1LocalState>> {
    const states: Map<string, V1LocalState> = new Map<string, V1LocalState>();
    if (ids.length === 0) {
      return states;
    }
    const columns: Set<string> = await this.db.columnsOf(table);
    const deletedAtSelect: string = columns.has('deleted_at') ? ', deleted_at AS deleted_at' : '';
    const coverUrlSelect: string = table === 'books' && columns.has('cover_url')
      ? ', cover_url AS cover_url'
      : '';
    const chunkSize: number = 200;
    for (let offset = 0; offset < ids.length; offset += chunkSize) {
      const chunk: string[] = ids.slice(offset, offset + chunkSize);
      const placeholders: string = chunk.map((): string => '?').join(', ');
      const resultSet = await this.db.rdbHandle.query(
        `SELECT ${pk} AS id, ${timestampCol} AS timestamp${deletedAtSelect}${coverUrlSelect}
         FROM ${table} WHERE ${pk} IN (${placeholders})`,
        chunk,
      );
      try {
        const idIndex: number = resultSet.getColumnIndex('id');
        const tsIndex: number = resultSet.getColumnIndex('timestamp');
        const delIndex: number = resultSet.getColumnIndex('deleted_at');
        const coverIndex: number = resultSet.getColumnIndex('cover_url');
        while (resultSet.goToNextRow()) {
          const id: string = idIndex < 0 ? '' : String(resultSet.getValue(idIndex));
          if (id.length === 0) {
            continue;
          }
          const ts: number = tsIndex < 0 || resultSet.isColumnNull(tsIndex)
            ? 0
            : numberCell(columnValue(resultSet.getValue(tsIndex)), 0);
          const del: number | null = delIndex < 0 || resultSet.isColumnNull(delIndex)
            ? null
            : normalizeDeletedAt(String(resultSet.getValue(delIndex)));
          const cover: string = coverIndex < 0 || resultSet.isColumnNull(coverIndex)
            ? ''
            : String(resultSet.getValue(coverIndex));
          const state: V1LocalState = { timestamp: ts, deletedAt: del, coverUrl: cover };
          states.set(id, state);
        }
      } finally {
        resultSet.close();
      }
    }
    // Local tombstones raise the comparison value: a row deleted here at T is
    // "as new as T", so a peer's older live row must not resurrect it.
    await this.overlayTombstones(table, ids, states);
    return states;
  }

  /** Fold `sync_tombstones` into the states map, keeping the newest value. */
  private async overlayTombstones(
    table: string,
    ids: string[],
    states: Map<string, V1LocalState>,
  ): Promise<void> {
    const chunkSize: number = 200;
    for (let offset = 0; offset < ids.length; offset += chunkSize) {
      const chunk: string[] = ids.slice(offset, offset + chunkSize);
      const placeholders: string = chunk.map((): string => '?').join(', ');
      const resultSet = await this.db.rdbHandle.query(
        `SELECT id, deleted_at FROM sync_tombstones
         WHERE table_name = ? AND id IN (${placeholders})`,
        [table].concat(chunk),
      );
      try {
        const idIndex: number = resultSet.getColumnIndex('id');
        const delIndex: number = resultSet.getColumnIndex('deleted_at');
        while (resultSet.goToNextRow()) {
          const id: string = idIndex < 0 ? '' : String(resultSet.getValue(idIndex));
          if (id.length === 0) {
            continue;
          }
          const deletedAt: number = delIndex < 0 || resultSet.isColumnNull(delIndex)
            ? 0
            : numberCell(columnValue(resultSet.getValue(delIndex)), 0);
          const existing: V1LocalState | undefined = states.get(id);
          if (existing === undefined) {
            const created: V1LocalState = { timestamp: deletedAt, deletedAt: null, coverUrl: '' };
            states.set(id, created);
          } else if (deletedAt > existing.timestamp) {
            existing.timestamp = deletedAt;
          }
        }
      } finally {
        resultSet.close();
      }
    }
  }

  async upsert(table: string, pk: string, record: WireRow): Promise<void> {
    const existing: Set<string> = await this.db.columnsOf(table);
    const columns: string[] = [];
    const values: Bindable[] = [];
    for (const column of Object.keys(record)) {
      if (!existing.has(column)) {
        continue;
      }
      const bound: Bindable | undefined = bindableValue(record[column]);
      if (bound === undefined) {
        continue;
      }
      columns.push(column);
      values.push(bound);
    }
    if (columns.length === 0 || !columns.includes(pk)) {
      return;
    }
    const placeholders: string = columns.map((): string => '?').join(', ');
    const updateColumns: string[] = columns.filter((c: string): boolean => c !== pk);
    // One statement, one `execute`. The reference splits this into two calls that
    // differ only in the conflict action (`DO NOTHING` when the row carries nothing
    // but its primary key, `DO UPDATE SET` otherwise); collapsing them changes no
    // behaviour and keeps a single row's write a single write, which is what the
    // data layer's multi-write audit expects of a method with no transaction
    // around it.
    const conflictAction: string = updateColumns.length === 0
      ? 'DO NOTHING'
      : `DO UPDATE SET ${updateColumns
        .map((c: string): string => `${c} = excluded.${c}`)
        .join(', ')}`;
    await this.db.rdbHandle.execute(
      `INSERT INTO ${table} (${columns.join(', ')})
       VALUES (${placeholders})
       ON CONFLICT(${pk}) ${conflictAction}`,
      values,
    );
  }

  async remove(table: string, pk: string, id: string): Promise<void> {
    await this.db.rdbHandle.execute(`DELETE FROM ${table} WHERE ${pk} = ?`, [id]);
  }

  async rememberTombstone(
    table: string,
    id: string,
    deletedAt: number,
    deviceId: string,
  ): Promise<void> {
    await this.db.rememberRemoteTombstone(id, table, deletedAt, deviceId, undefined);
  }
}

// ---------------------------------------------------------------------------
// The `books`-only path rules
// ---------------------------------------------------------------------------
//
// Moved to `./V1BookPaths` so the v1 file phase can use them without importing this
// engine. Re-exported here because this module is where the v1 protocol's surface has
// always been read from, and every existing caller and audit reads it from here. The
// import itself is at the top of the file, with the others.

export {
  bookFilePathForExtension,
  canonicalBookCoverPath,
  canonicalBookFilePath,
  isCanonicalCoverPath,
  isConvertedSourceFormat,
  isCustomCoverPath,
  resolveBookExtension,
};

/**
 * Localize an incoming `books` row.
 *
 * Ported from `localizeSyncedBookRecord`. When the incoming row carries no usable
 * `id`/`file_path` the reference returns the record **unchanged** — so
 * `sync_status` and `cover_url` keep whatever the peer sent. That early return is
 * reproduced exactly: it is not a special case worth "fixing", because a row
 * without an id cannot be applied at all (the upsert is keyed on it) and
 * rewriting its cover would be a change nobody could observe.
 *
 * When it does apply, three cells are replaced: `file_path` becomes this
 * device's canonical path, `cover_url` is canonicalised, and `sync_status` is
 * forced to `"remote"`. The last is the point of the function: the row describes
 * a book whose *file* is on the peer, so on arrival it is remote here until the
 * binary pass fetches it.
 *
 * **`cover_url` is always assigned, `null` included.** The reference is
 * `{...record, file_path, cover_url: canonicalBookCoverPath(id, record.cover_url),
 * sync_status: "remote"}` (v1.3.6 `simple-sync.ts:446-457`), so a peer with no
 * cover emits `cover_url: null` — and that null is *acted on*, not dropped:
 * `filterRecordToExistingColumns` (`:132-141`) filters by column **name** only, so
 * a key present with a `null` value survives into
 * `INSERT … ON CONFLICT DO UPDATE SET cover_url = excluded.cover_url` and clears
 * the column here. Omitting the key instead would leave the local value in place,
 * and a cover the peer has deleted would live on in this database forever. This is
 * exactly why `WireRow` has to be able to hold `null`.
 */
export function localizeSyncedBookRecord(record: WireRow): WireRow {
  const id: Object | null | undefined = record['id'];
  const filePath: string = canonicalBookFilePath(id, record['file_path'], record['format']);
  if (filePath.length === 0) {
    return record;
  }
  const out: WireRow = {};
  for (const key of Object.keys(record)) {
    out[key] = record[key];
  }
  out['file_path'] = filePath;
  out['cover_url'] = canonicalBookCoverPath(id, record['cover_url']);
  out['sync_status'] = 'remote';
  return out;
}

/**
 * Keep a locally chosen custom cover when the peer offers only its canonical one.
 *
 * Ported from `preserveLocalCustomBookCover`. Applied to the **localized** record,
 * so the remote side of the comparison is already canonical — which is why the
 * `isCanonicalCoverPath` test is the meaningful one, and why a peer's
 * `covers/{id}-custom-x.jpg` (canonicalized to itself) is correctly treated as a
 * custom cover.
 */
export function preserveLocalCustomBookCover(
  record: WireRow,
  local: V1LocalState | undefined,
): WireRow {
  const id: Object | null | undefined = record['id'];
  const bookId: string = typeof id === 'string' ? id : '';
  const localCoverUrl: string = local === undefined ? '' : local.coverUrl;
  if (bookId.length === 0 || !isCustomCoverPath(bookId, localCoverUrl)) {
    return record;
  }
  const remoteCoverUrl: Object | null | undefined = record['cover_url'];
  if (isCustomCoverPath(bookId, remoteCoverUrl)) {
    return record;
  }
  if (!isCanonicalCoverPath(bookId, remoteCoverUrl)) {
    return record;
  }
  hilog.info(DOMAIN, TAG,
    'preserving local custom cover for book %{public}s while applying remote metadata',
    shortId(bookId));
  const out: WireRow = {};
  for (const key of Object.keys(record)) {
    out[key] = record[key];
  }
  out['cover_url'] = localCoverUrl;
  return out;
}

// ---------------------------------------------------------------------------
// The merge
// ---------------------------------------------------------------------------

/** How one table's records pass went. */
interface ApplyOutcome {
  applied: number;
  skipped: number;
  refusedDeletions: number;
}

/** A record stripped of the columns that must not cross the wire. */
function withoutExcludedColumns(
  record: WireRow,
  exclude: string[],
): WireRow {
  if (exclude.length === 0) {
    return record;
  }
  const out: WireRow = {};
  for (const key of Object.keys(record)) {
    if (exclude.includes(key)) {
      continue;
    }
    out[key] = record[key];
  }
  return out;
}

/**
 * Apply one table's changeset.
 *
 * Row-level last-writer-wins, **not** per-field: for each incoming record the
 * whole row is written when it wins, and one column's newer value does not pull
 * the rest of the row along with it.
 *
 * The comparison is `shouldApplyRemoteRecord`, reused unchanged from
 * `sync/ShouldApply.ets` so this path and the v2 path cannot disagree about a
 * merge: no local row → apply; remote strictly newer → apply; remote strictly
 * older → skip; a tie → the local row, **except** for the `books` tie-break,
 * where an incoming record that carries its own `deleted_at` and a greater one
 * wins. That exception exists because ReadAny represents a "deleted but kept"
 * book as an ordinary row with `deleted_at` set, so a tie must not leave two
 * devices permanently split between a live and a deleted copy.
 *
 * Deletions run in a second loop, after every record, and the reference order is
 * preserved exactly — including the "stale tombstone for a live record" skip,
 * which is what stops a peer's old deletion from fighting a resurrection carried
 * in the same payload.
 */
async function applyTableChanges(
  writer: V1RecordWriter,
  config: V1TableConfig,
  changeset: TableChangeset,
  deviceId: string,
  forceApply: boolean,
  now: number,
  counts: V1SyncCounts,
): Promise<ApplyOutcome> {
  const outcome: ApplyOutcome = { applied: 0, skipped: 0, refusedDeletions: 0 };

  const ids: string[] = [];
  for (const record of changeset.records) {
    const id: string = pkOf(record, config.pk);
    if (id.length > 0) {
      ids.push(id);
    }
  }
  for (const rawId of changeset.deletedIds) {
    ids.push(typeof rawId === 'string' ? rawId : String(rawId));
  }

  const states: Map<string, V1LocalState> =
    await writer.loadStates(config.name, config.pk, config.timestampCol, ids);

  const remoteRecordIds: Set<string> = new Set<string>();
  for (const record of changeset.records) {
    const id: string = pkOf(record, config.pk);
    if (id.length > 0) {
      remoteRecordIds.add(id);
    }
  }

  const existingColumns: Set<string> = await writer.columnsOf(config.name);

  for (const record of changeset.records) {
    const id: string = pkOf(record, config.pk);
    if (id.length === 0) {
      // No primary key: there is nothing to key the upsert on. The reference
      // passes `undefined` to its driver and relies on the driver to cope; here
      // it is skipped and counted, which fails closed.
      outcome.skipped++;
      counts.skippedRows++;
      continue;
    }

    // A column this client's schema does not have is dropped before the write,
    // never bound. The reference lets its driver ignore unknown keys; passing one
    // through here would fail the whole statement and abandon the table.
    const known: WireRow = {};
    let droppedColumns: number = 0;
    for (const column of Object.keys(record)) {
      if (existingColumns.has(column)) {
        known[column] = record[column];
      } else {
        droppedColumns++;
      }
    }
    if (!hasBindableColumn(known)) {
      outcome.skipped++;
      counts.skippedRows++;
      continue;
    }
    if (droppedColumns > 0) {
      hilog.debug(DOMAIN, TAG,
        'dropping %{public}d unknown column(s) from a %{public}s row: %{public}s',
        droppedColumns, config.name, recordShapeOf(record));
    }

    // Order matches the reference exactly: exclude → localize → cover preservation.
    const safeRecord: WireRow =
      withoutExcludedColumns(known, config.excludeColumns);
    const localized: WireRow = config.name === 'books'
      ? localizeSyncedBookRecord(safeRecord)
      : safeRecord;
    const local: V1LocalState | undefined = states.get(id);
    const localState: LocalRecordState | undefined = local === undefined
      ? undefined
      : localRecordState(local.timestamp, local.deletedAt);
    const reader: FieldReader = jsonReader(record);

    if (!forceApply && !shouldApplyRemoteRecord(reader, config.timestampCol, localState)) {
      outcome.skipped++;
      continue;
    }

    const toWrite: WireRow = config.name === 'books'
      ? preserveLocalCustomBookCover(localized, local)
      : localized;

    try {
      await writer.upsert(config.name, config.pk, toWrite);
    } catch (err) {
      // One unwritable row must not abandon the rest of the table. The realistic
      // causes are a foreign key whose parent has not arrived yet — annotations
      // reference a book, and the apply order puts `books` first for exactly that
      // reason — and a constraint on a column the peer filled differently. The
      // next pass re-reads the same payload and retries.
      hilog.warn(DOMAIN, TAG, 'skipping %{public}s row %{public}s: %{public}s',
        config.name, shortId(id), String(err));
      outcome.skipped++;
      counts.skippedRows++;
      continue;
    }

    outcome.applied++;
    const applied: V1LocalState = {
      timestamp: numberCell(record[config.timestampCol], 0),
      // `columnValue` first: a wire row's cells are `Object | null`, and the
      // coercion to the three JSON kinds is what makes the value something
      // `normalizeDeletedAt` can read. A nested value it cannot read becomes
      // `undefined`, which normalize maps to `null` — the same verdict it reaches
      // on its own for a value of the wrong type.
      deletedAt: normalizeDeletedAt(columnValue(record['deleted_at'])),
      coverUrl: local === undefined ? '' : local.coverUrl,
    };
    states.set(id, applied);
  }

  const violation: ChangesetViolation = unjustifiedDeletions(changeset, config.name);
  outcome.refusedDeletions = violation.unjustified.length;
  counts.refusedDeletions += violation.unjustified.length;
  const justified: Record<string, number> = changeset.deletedTimestamps as Record<string, number>;

  for (const rawId of changeset.deletedIds) {
    const id: string = typeof rawId === 'string' ? rawId : String(rawId);
    if (remoteRecordIds.has(id)) {
      // The same payload carries a live row for this id, so the tombstone is
      // stale: the item was resurrected and travels as a record. Deleting it here
      // would destroy the resurrection.
      hilog.warn(DOMAIN, TAG,
        'ignoring stale tombstone for live %{public}s/%{public}s from device %{public}s',
        config.name, shortId(id), shortId(deviceId));
      outcome.skipped++;
      continue;
    }

    if (violation.unjustified.includes(id)) {
      hilog.error(DOMAIN, TAG,
        'refusing unexplained deletion of %{public}s/%{public}s from device %{public}s: '
        + 'deletedTimestamps carries no positive value, and applying it would delete the row '
        + 'with no comparison at all',
        config.name, shortId(id), shortId(deviceId));
      outcome.skipped++;
      continue;
    }

    const deletedAt: number = justified[id];

    if (!isPlausibleTombstone(deletedAt, now)) {
      // A deletion dated implausibly far in the future satisfies every ordering
      // comparison, so it would delete the row and write a sticky tombstone that
      // no re-pull could undo. Ignored, never applied; the remote file is
      // untouched and the same verdict is reached next pass.
      hilog.warn(DOMAIN, TAG,
        'ignoring implausible %{public}s deletion of %{public}s from device %{public}s: '
        + 'deletedAt=%{public}s is beyond now + the tombstone bound',
        config.name, shortId(id), shortId(deviceId), String(deletedAt));
      outcome.skipped++;
      continue;
    }

    const local: V1LocalState | undefined = states.get(id);
    const localTimestamp: number = local === undefined ? 0 : local.timestamp;
    if (!shouldApplyTombstone(deletedAt, localTimestamp, forceApply)) {
      hilog.info(DOMAIN, TAG,
        'keeping %{public}s/%{public}s: the local copy is newer (%{public}s > %{public}s)',
        config.name, shortId(id), String(localTimestamp), String(deletedAt));
      outcome.skipped++;
      continue;
    }

    try {
      await writer.remove(config.name, config.pk, id);
      await writer.rememberTombstone(config.name, id, deletedAt, deviceId);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'failed to delete %{public}s/%{public}s: %{public}s',
        config.name, shortId(id), String(err));
      outcome.skipped++;
      continue;
    }
    outcome.applied++;
    const deleted: V1LocalState = { timestamp: deletedAt, deletedAt: null, coverUrl: '' };
    states.set(id, deleted);
  }

  return outcome;
}

/**
 * Apply one parsed snapshot.
 *
 * Tables are iterated in `V1_SYNC_TABLES` order, not in the order the payload
 * happens to list them. That is deliberate and load-bearing: the order is
 * parents-before-children, and applying `highlights` before `books` would make
 * every one of them fail its foreign key on a first sync.
 *
 * A table in the payload that this client has no table for is counted and
 * skipped. It is never created, and — critically — this device's inability to
 * honour its tombstones is never reported back as a deletion of its own.
 */
export async function applyDeviceSnapshot(
  writer: V1RecordWriter,
  payload: ParsedDeviceSnapshot,
  forceApply: boolean,
  now: number,
  counts: V1SyncCounts,
): Promise<void> {
  for (const config of V1_SYNC_TABLES) {
    const changeset: TableChangeset | undefined = payload.tables.get(config.name);
    if (changeset === undefined) {
      continue;
    }
    hilog.info(DOMAIN, TAG,
      'applying %{public}s: %{public}d record(s), %{public}d deletion(s)',
      config.name, changeset.records.length, changeset.deletedIds.length);
    const outcome: ApplyOutcome = await applyTableChanges(
      writer, config, changeset, payload.deviceId, forceApply, now, counts,
    );
    counts.applied += outcome.applied;
    counts.skipped += outcome.skipped;
  }

  for (const table of payload.tables.keys()) {
    if (v1TableConfig(table) === undefined) {
      counts.skippedTables++;
      hilog.info(DOMAIN, TAG,
        'ignoring table %{public}s: this client has no such table, so it neither '
        + 'applies nor reports anything about it', table);
    }
  }
}

// ---------------------------------------------------------------------------
// Collecting local changes
// ---------------------------------------------------------------------------

/**
 * One table's local changes.
 *
 * Returns `undefined` when the table must be **omitted** from the payload. The
 * only way to reach that is genuinely having nothing to say: no records and no
 * tombstones. A table that does not exist locally, or whose tombstone query
 * fails, produces exactly that — an omission — because emitting an empty or
 * partial changeset is what would tell a peer "these rows are gone".
 */
export async function collectTableChanges(
  db: Database,
  config: V1TableConfig,
  since: number,
): Promise<TableChangeset | undefined> {
  const columns: Set<string> = await db.columnsOf(config.name);
  if (columns.size === 0) {
    hilog.info(DOMAIN, TAG,
      'omitting table %{public}s from the snapshot: this client has no such table',
      config.name);
    return undefined;
  }

  const records: WireRow[] = [];
  const resultSet = await db.rdbHandle.query(
    `SELECT * FROM ${config.name} WHERE ${config.timestampCol} > ?`,
    [since],
  );
  try {
    const names: string[] = [];
    for (let i = 0; i < resultSet.columnCount; i++) {
      names.push(resultSet.getColumnName(i));
    }
    while (resultSet.goToNextRow()) {
      const row: WireRow = {};
      for (let i = 0; i < names.length; i++) {
        if (config.excludeColumns.includes(names[i])) {
          continue;
        }
        // SQL NULL is written as JSON `null`, not omitted. The protocol says a row
        // travels with its native JSON types and its nulls preserved, and the two
        // are not interchangeable on the receiving side: an omitted column means
        // "leave mine alone", while `null` means "mine is empty".
        if (resultSet.isColumnNull(i)) {
          row[names[i]] = null;
          continue;
        }
        const value: string | number | boolean | undefined = columnCell(resultSet.getValue(i));
        // A value that cannot be represented in JSON is omitted rather than
        // stringified, which leaves the receiver's own value in place. This is a
        // logged skip inside `columnCell`, never a silent coercion.
        if (value !== undefined) {
          row[names[i]] = value;
        }
      }
      records.push(row);
    }
  } finally {
    resultSet.close();
  }

  const deletedIds: string[] = [];
  const deletedTimestamps: Record<string, number> = {};
  try {
    const tombstones = await db.rdbHandle.query(
      `SELECT id, deleted_at FROM sync_tombstones
       WHERE table_name = ?
         AND deleted_at > ?
         AND deleted_at > 0
         AND NOT EXISTS (SELECT 1 FROM ${config.name} WHERE ${config.pk} = sync_tombstones.id)`,
      [config.name, since],
    );
    try {
      const idIndex: number = tombstones.getColumnIndex('id');
      const delIndex: number = tombstones.getColumnIndex('deleted_at');
      while (tombstones.goToNextRow()) {
        const id: string = idIndex < 0 ? '' : String(tombstones.getValue(idIndex));
        const deletedAt: number = delIndex < 0 || tombstones.isColumnNull(delIndex)
          ? 0
          : numberCell(columnValue(tombstones.getValue(delIndex)), 0);
        if (id.length === 0) {
          continue;
        }
        // The pairing rule is enforced at the write, not left to the reader: an id
        // without a positive timestamp is dropped from the payload rather than
        // published as a deletion a peer would apply with no comparison.
        if (!Number.isFinite(deletedAt) || deletedAt <= 0) {
          hilog.error(DOMAIN, TAG,
            'dropping tombstone for %{public}s/%{public}s: its deleted_at is not a positive '
            + 'millisecond value, and publishing it would make every peer hard-delete the row '
            + 'with no comparison',
            config.name, shortId(id));
          continue;
        }
        deletedIds.push(id);
        deletedTimestamps[id] = deletedAt;
      }
    } finally {
      tombstones.close();
    }
  } catch (err) {
    // `sync_tombstones` may not exist on an older schema. An empty tombstone set
    // is safe: it means "this device deletes nothing", never "this device's rows
    // are gone".
    hilog.debug(DOMAIN, TAG, 'no tombstones readable for %{public}s: %{public}s',
      config.name, String(err));
  }

  if (records.length === 0 && deletedIds.length === 0) {
    return undefined;
  }
  const changeset: TableChangeset = {
    records: records,
    deletedIds: deletedIds,
    // Set whenever there is anything at all to say, exactly as the reference
    // does; it is an empty object in the record-only case, where the pairing rule
    // is vacuous. The rule that carries the risk is the one guarded above.
    deletedTimestamps: deletedTimestamps,
  };
  return changeset;
}

/**
 * Collect a device's whole state as a snapshot payload.
 *
 * `since` is recorded in the payload for the peer's benefit and is **0** for
 * every push this engine makes: the reference always uploads the full snapshot
 * (`collectChanges(0)`) and computes a delta only to decide *whether* to push.
 * That is not an optimisation detail — it is what lets a device that has been
 * offline for a year still bootstrap a fresh peer, and it is why tombstones are
 * accumulative: the snapshot carries the device's complete deletion history, and
 * nothing here prunes it.
 */
export async function collectDeviceSnapshot(
  db: Database,
  deviceId: string,
  since: number,
  now: number,
): Promise<DeviceSyncPayload> {
  const tables: Record<string, TableChangeset> = {};
  for (const config of V1_SYNC_TABLES) {
    const changeset: TableChangeset | undefined = await collectTableChanges(db, config, since);
    if (changeset !== undefined) {
      tables[config.name] = changeset;
    }
  }
  const payload: DeviceSyncPayload = {
    deviceId: deviceId,
    timestamp: now,
    since: since,
    tables: tables,
  };
  return payload;
}

/**
 * The payload as it goes on the wire.
 *
 * `deletedTimestamps` is written **iff** `deletedIds` is non-empty, built from
 * the same ids in the same pass so it cannot drift. `JSON.stringify` of the
 * interfaces would be equivalent for the happy path, but going through an
 * explicit serializer puts the pairing rule in one visible place and stops a
 * future field added to `TableChangeset` from reaching the wire unplanned.
 */
export function payloadToWire(payload: DeviceSyncPayload): Record<string, Object> {
  const tables: Record<string, Object> = {};
  for (const table of Object.keys(payload.tables)) {
    const changeset: TableChangeset = payload.tables[table];
    const out: Record<string, Object> = {};
    out['records'] = changeset.records;
    const stamps: Record<string, number> | undefined = changeset.deletedTimestamps;
    if (changeset.deletedIds.length > 0 && stamps !== undefined) {
      out['deletedIds'] = changeset.deletedIds;
      out['deletedTimestamps'] = stamps;
    } else if (changeset.deletedIds.length > 0) {
      // Unreachable through `collectTableChanges`; kept because the cost of being
      // wrong is a peer deleting the user's rows. The ids are dropped rather than
      // published unexplained.
      hilog.error(DOMAIN, TAG,
        'dropping %{public}d unexplained deletion(s) from %{public}s at serialization time',
        changeset.deletedIds.length, table);
      out['deletedIds'] = [];
    } else {
      out['deletedIds'] = [];
    }
    tables[table] = out;
  }
  const wire: Record<string, Object> = {};
  wire['deviceId'] = payload.deviceId;
  wire['timestamp'] = payload.timestamp;
  wire['since'] = payload.since;
  wire['tables'] = tables;
  return wire;
}

/** The index as it goes on the wire. */
export function indexToWire(index: DeviceSyncIndex): Record<string, Object> {
  const devices: Record<string, Object> = {};
  for (const deviceId of Object.keys(index.devices)) {
    const entry: DeviceIndexEntry = index.devices[deviceId];
    const out: Record<string, Object> = {};
    out['path'] = entry.path;
    out['timestamp'] = entry.timestamp;
    devices[deviceId] = out;
  }
  const wire: Record<string, Object> = {};
  wire['version'] = index.version;
  wire['updatedAt'] = index.updatedAt;
  wire['devices'] = devices;
  return wire;
}

/** Records plus tombstones in a payload, the reference's "change count". */
export function countChanges(payload: DeviceSyncPayload): number {
  let total: number = 0;
  for (const table of Object.keys(payload.tables)) {
    const changeset: TableChangeset = payload.tables[table];
    total += changeset.records.length + changeset.deletedIds.length;
  }
  return total;
}

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

/** How a pass's discovery step went. */
interface DeviceDiscovery {
  devices: V1RemoteDevice[];
  indexKind: V1IndexKind;
  indexRecord: Record<string, Object> | undefined;
  /**
   * Set when the index exists, is not v1, and therefore blocks the index write.
   * Empty when writing the index is allowed.
   */
  indexRefusal: string;
}

/**
 * Coerce a caught value into an `InkBoatError`.
 *
 * ArkTS forbids `throw` with a non-Error type and forbids type annotations in a
 * `catch`, so a rethrow is re-wrapped; an already-classified error keeps its kind
 * and HTTP status.
 */
function asInkBoatError(cause: Object | undefined, fallback: string): InkBoatError {
  if (cause instanceof InkBoatError) {
    return cause;
  }
  if (cause instanceof Error) {
    return new InkBoatError(SyncErrorKind.NETWORK, cause.message, 0, '', '');
  }
  return new InkBoatError(SyncErrorKind.UNKNOWN, fallback, 0, '', '');
}

export class SyncV1Engine {
  private readonly client: WebDavClient;
  private readonly config: WebDavConfig;
  private readonly db: Database;
  private readonly writer: V1RecordWriter;
  private readonly clock: () => number;
  /**
   * The file phase, or `undefined` for a metadata-only engine.
   *
   * Undefined is a supported configuration and not a degraded one: `runSync` then does
   * everything it did before files were in scope, and the file counters come back zero.
   * The v1 engine is constructed with a runner by `SyncService.ensureV1Engine`, so a pass
   * started from the settings screen has one; a test or a probe that only wants the merge
   * can omit it.
   */
  private readonly files: V1FileRunner | undefined;

  constructor(
    client: WebDavClient,
    config: WebDavConfig,
    db: Database,
    writer?: V1RecordWriter,
    clock?: () => number,
    files?: V1FileRunner,
  ) {
    this.client = client;
    this.config = config;
    this.db = db;
    this.clock = clock ?? systemClock;
    this.writer = writer ?? new RdbRecordWriter(db);
    this.files = files;
  }

  /** Map a logical protocol path onto the user's configured remote root. */
  private path(logicalPath: string): string {
    return resolveRemotePath(
      { baseUrl: this.config.url, remoteRoot: this.config.remoteRoot },
      logicalPath,
    );
  }

  /**
   * Create the directory the snapshots live in.
   *
   * **`/readany/sync` only, and one MKCOL.** The book-file tree
   * (`/readany/data/books/{title}-{id}/`, `/readany/data/file`, `/readany/data/cover`) is
   * the file phase's business: `V1FilePhase.ensureRemoteLayout` creates it, and that class
   * is the only thing in the v1 path that knows a book file exists. Keeping the two apart
   * is what makes `verify-sync-routing.mjs`'s claim about this file checkable rather than
   * rhetorical — there is no `/readany/data` path here to audit, because there is none.
   *
   * What the file phase is *handed* it must not be able to do either: `V1FileRunner` has
   * one method and no delete, no move and no listing on it, so v1.3.6's
   * `cleanupRemoteOrphans` — which needs a listing and a `DELETE` — cannot be expressed
   * against the interface this engine holds.
   */
  async ensureRemoteLayout(): Promise<void> {
    try {
      await this.client.ensureDirectory(this.path(V1_SYNC_DIR));
    } catch (err) {
      // The reference wraps this failure with the same advice, and for the same
      // reason: a sync that cannot create its own directory produces a cascade of
      // confusing per-file errors, so the first one is reported as what it is.
      throw new InkBoatError(
        SyncErrorKind.NETWORK,
        `无法创建远程同步目录，请检查存储服务配置和权限：${String(err)}`,
      );
    }
  }

  /** Read a document, treating "absent" as an empty string. */
  private async readTextIfPresent(logicalPath: string): Promise<string> {
    try {
      const bytes: Uint8Array = await this.client.getBytes(this.path(logicalPath));
      return utf8Decode(bytes);
    } catch (err) {
      if (err instanceof InkBoatError && err.kind === SyncErrorKind.NOT_FOUND) {
        return '';
      }
      throw asInkBoatError(err, `读取 ${logicalPath} 失败`);
    }
  }

  /** Read and classify the remote index. Writes nothing. */
  async loadIndex(): Promise<V1IndexLoad> {
    const text: string = await this.readTextIfPresent(V1_INDEX_PATH);
    const document = readJsonDocument(text);
    if (document.outcome === JsonReadOutcome.UNPARSEABLE) {
      // A body that is not JSON is not an absent index. The distinction is the
      // whole reason `readJsonDocument` exists: treating it as empty is how a
      // client overwrites a document it merely failed to understand.
      hilog.error(DOMAIN, TAG, 'the remote index is not JSON: %{public}s', document.excerpt);
      const unparseable: V1IndexLoad = {
        kind: V1IndexKind.UNPARSEABLE,
        devices: new Map<string, DeviceIndexEntry>(),
        record: undefined,
      };
      return unparseable;
    }
    const record: Record<string, Object> | undefined = document.record;
    const kind: V1IndexKind = classifyV1Index(record);
    const result: V1IndexLoad = {
      kind: kind,
      devices: kind === V1IndexKind.INDEX_V1
        ? readDeviceEntries(record)
        : new Map<string, DeviceIndexEntry>(),
      record: record,
    };
    return result;
  }

  /**
   * List every device snapshot the server holds.
   *
   * Two sources, and the **directory listing wins** on a conflict. The index is
   * only a discovery cache: it is not pruned, it is not authoritative, and a
   * device that wrote its snapshot but failed to update the index would be
   * invisible if the index were trusted. The listing is the server's own answer
   * about which files exist, which is what the reference consults second and
   * overlays first.
   *
   * Discovery never depends on the index being readable. A `device-*.json` found
   * by listing is pulled even when `index.json` is a document this engine refuses
   * to write — reading and writing are separate decisions, and conflating them
   * would make a v2 index silently hide every v1 snapshot.
   */
  async discoverDevices(): Promise<DeviceDiscovery> {
    const index: V1IndexLoad = await this.loadIndex();
    const byDevice: Map<string, V1RemoteDevice> = new Map<string, V1RemoteDevice>();
    index.devices.forEach((entry: DeviceIndexEntry, deviceId: string): void => {
      byDevice.set(deviceId, { deviceId: deviceId, path: entry.path, fromIndex: true });
    });

    let entries: RemoteListing[] = [];
    try {
      const resources = await this.client.safeListDir(this.path(V1_SYNC_DIR));
      for (const resource of resources) {
        const listing: RemoteListing = {
          name: resource.name,
          isCollection: resource.isCollection,
        };
        entries.push(listing);
      }
    } catch (err) {
      // An unlistable directory costs discovery breadth, not correctness: whatever
      // the index named is still pulled.
      hilog.warn(DOMAIN, TAG, 'failed to list the remote sync directory: %{public}s', String(err));
    }
    for (const entry of entries) {
      if (entry.isCollection) {
        continue;
      }
      const name: string = entry.name;
      if (!name.startsWith(DEVICE_FILE_PREFIX) || !name.endsWith(DEVICE_FILE_SUFFIX)) {
        continue;
      }
      const deviceId: string = name.substring(
        DEVICE_FILE_PREFIX.length, name.length - DEVICE_FILE_SUFFIX.length,
      );
      if (deviceId.length === 0) {
        continue;
      }
      // The path is built from the device id rather than taken from the listing,
      // because a PROPFIND href is a server URL and this engine speaks logical
      // paths. The two agree by construction: a device id can only have come from
      // a `device-<id>.json` name.
      byDevice.set(deviceId, {
        deviceId: deviceId,
        path: v1DevicePath(deviceId),
        fromIndex: false,
      });
    }

    const devices: V1RemoteDevice[] = [];
    byDevice.forEach((device: V1RemoteDevice): void => {
      devices.push(device);
    });

    const discovery: DeviceDiscovery = {
      devices: devices,
      indexKind: index.kind,
      indexRecord: index.record,
      indexRefusal: isWritableV1IndexKind(index.kind)
        ? ''
        : indexRefusalMessage(index.kind, index.record),
    };
    return discovery;
  }

  /**
   * Write this device's snapshot, then merge this device's entry into the index.
   *
   * **Never touches another device's file.** The snapshot path is derived from
   * the local device id and nothing else, and no `DELETE` is ever issued for a
   * `device-*.json` — the reference never does either. A device's snapshot is its
   * own complete history, so deleting one is not a sync operation at all.
   *
   * The index write is a **merge**: the index is re-read immediately before the
   * write, every other device's entry is carried over unchanged, and only this
   * device's entry is set. An index write built from the in-memory snapshot taken
   * at the start of the pass would drop every device that wrote in between, and
   * because the index is only a *discovery cache* the loss is not immediate — the
   * affected devices stay invisible until their own next pass re-adds them, which
   * for a device the user has stopped using is forever.
   */
  async saveDeviceSnapshot(payload: DeviceSyncPayload): Promise<boolean> {
    const logical: string = v1DevicePath(payload.deviceId);
    await this.client.putText(
      this.path(logical),
      JSON.stringify(payloadToWire(payload)),
      'application/json',
    );

    const fresh: V1IndexLoad = await this.loadIndex();
    if (!isWritableV1IndexKind(fresh.kind)) {
      // Fail closed. An index this engine cannot positively read as v1 is not
      // "empty": it is a document it does not understand, and writing this
      // device's own three keys over it would erase whatever it holds. The
      // snapshot above is already on the server, so nothing is lost by stopping
      // here — the next pass retries and the user is told why.
      hilog.error(DOMAIN, TAG,
        'refusing to write the remote index: it is %{public}s, not a v1 device index',
        String(fresh.kind));
      return false;
    }

    const devices: Record<string, DeviceIndexEntry> = {};
    fresh.devices.forEach((entry: DeviceIndexEntry, deviceId: string): void => {
      devices[deviceId] = entry;
    });
    const own: DeviceIndexEntry = { path: logical, timestamp: payload.timestamp };
    devices[payload.deviceId] = own;

    const next: DeviceSyncIndex = {
      version: V1_INDEX_VERSION,
      updatedAt: this.clock(),
      devices: devices,
    };
    await this.client.putText(
      this.path(V1_INDEX_PATH),
      JSON.stringify(indexToWire(next)),
      'application/json',
    );
    hilog.info(DOMAIN, TAG, 'index updated with %{public}d device(s)', Object.keys(devices).length);
    return true;
  }

  /** Read one device's snapshot. Returns `undefined` when it is not one. */
  async loadSnapshot(logicalPath: string): Promise<ParsedDeviceSnapshot | undefined> {
    const text: string = await this.readTextIfPresent(logicalPath);
    const document = readJsonDocument(text);
    if (document.outcome !== JsonReadOutcome.PARSED) {
      return undefined;
    }
    return parseDeviceSnapshot(document.record);
  }

  /**
   * Run one pass.
   *
   * Order, and why:
   *  1. make sure the remote directory exists;
   *  2. discover and pull every other device's snapshot, applying it;
   *  3. only then collect and push this device's own — after every remote row has
   *     landed, so what is published is the **merged** state and not a pre-merge
   *     view that the next peer to read it would take as the truth;
   *  4. and last, the file phase: book files and covers, which read the `books` rows the
   *     metadata phase has just finished merging. Running it earlier would plan transfers
   *     from a pre-merge view of which books exist and where their files are.
   *
   * The file phase is **additive and non-destructive by construction**. Nothing it can do
   * removes a remote object or moves one: it creates folders (`MKCOL`), uploads
   * (`PUT` book files and covers), downloads when asked (and covers when missing), and
   * rewrites the manifest. v1.3.6's three destructive routines —
   * `cleanupRemoteOrphans`, `cleanupLocalOrphans`, `migrateBookRemoteState` — are not
   * implemented anywhere in this client, so they cannot be reached from here or from
   * anywhere else. See `V1FilePhase.ets`'s header for what that costs and why the trade is
   * the right way round.
   *
   * A file-phase failure is **counted, not fatal**: the metadata pass that already
   * succeeded keeps its result, and the transfer that failed is retried on the next pass.
   * What is *not* tolerated is a manifest that could not be read — the write is abandoned
   * rather than replaced by a narrower document, and `files.manifestRefused` says so.
   */
  async runSync(options: V1SyncOptions, onProgress?: V1ProgressFn): Promise<V1SyncResult> {
    const counts: V1SyncCounts = emptyV1SyncCounts();
    const files: V1FileSyncCounts = emptyV1FileSyncCounts();
    const appliedDevices: string[] = [];
    const startedAt: number = this.clock();
    try {
      this.report(onProgress, '准备同步...', 0, 0);
      await this.ensureRemoteLayout();

      const localDeviceId: string = await this.db.getDeviceId();

      this.report(onProgress, '获取其他设备的变更...', 0, 0);
      const discovery: DeviceDiscovery = await this.discoverDevices();
      const total: number = discovery.devices.length;
      let processed: number = 0;

      // One clock reading for the whole pass, so every tombstone in every snapshot
      // this pass reads is judged against the same "now". Re-reading the clock per
      // file would let a slow transfer push a payload that was inside the bound at
      // the start of the pass outside it by the end.
      const now: number = startedAt;

      for (const device of discovery.devices) {
        processed++;
        if (device.deviceId === localDeviceId) {
          continue;
        }
        this.report(onProgress, `应用设备 ${shortId(device.deviceId)} 的变更...`, processed, total);
        let snapshot: ParsedDeviceSnapshot | undefined;
        try {
          snapshot = await this.loadSnapshot(device.path);
        } catch (err) {
          // One unreadable peer must not abort the pass: its own snapshot is
          // untouched and the next pass retries. The reference counts and skips
          // for the same reason.
          hilog.warn(DOMAIN, TAG, 'skipping unreadable snapshot from device %{public}s: %{public}s',
            shortId(device.deviceId), String(err));
          continue;
        }
        if (snapshot === undefined) {
          hilog.warn(DOMAIN, TAG, 'skipping unparseable snapshot from device %{public}s',
            shortId(device.deviceId));
          continue;
        }
        await applyDeviceSnapshot(this.writer, snapshot, options.forceApply, now, counts);
        appliedDevices.push(device.deviceId);
      }

      const uploaded: boolean = await this.pushOwnSnapshot(
        localDeviceId, options, counts, startedAt, onProgress,
      );

      // ---- file phase -------------------------------------------------------
      // After the metadata, because the file phase plans from the `books` rows and those
      // rows have only just finished merging. The runner is optional; without one this
      // whole block is skipped and the counters stay zero, which is the honest report of
      // a pass that moved no files.
      if (this.files !== undefined) {
        const binary: BinarySyncOptions = defaultBinaryOptions();
        binary.forceUploadAll = options.forceUploadAll;
        binary.forceDownloadAll = options.forceDownloadAll;
        binary.downloadRemoteBooks = options.downloadRemoteBooks;
        binary.disableUploads = options.disableUploads;
        this.report(onProgress, '同步书籍文件...', 0, 0);
        const moved: V1FileCounts = await this.files.runFilePhase(
          binary,
          (message: string, completed: number, total: number): void => {
            this.report(onProgress, message, completed, total);
          },
        );
        files.filesUploaded = moved.uploaded;
        files.filesDownloaded = moved.downloaded;
        files.filesFailed = moved.failed;
        files.manifestRefused = moved.manifestRefused;
        files.manifestError = moved.manifestError;
        files.phaseError = moved.error;
        files.firstFailure = moved.firstFailure;
      }

      await this.db.setLastSyncAt(this.clock());
      this.report(onProgress, '同步完成', 0, 0);

      const result: V1SyncResult = {
        success: true,
        counts: counts,
        appliedDevices: appliedDevices,
        uploaded: uploaded,
        error: '',
        files: files,
      };
      return result;
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      hilog.error(DOMAIN, TAG, 'sync failed: %{public}s', message);
      const failed: V1SyncResult = {
        success: false,
        counts: counts,
        appliedDevices: appliedDevices,
        uploaded: false,
        error: message,
        files: files,
      };
      return failed;
    }
  }

  /** Decide whether this device's snapshot needs publishing, and publish it. */
  private async pushOwnSnapshot(
    localDeviceId: string,
    options: V1SyncOptions,
    counts: V1SyncCounts,
    startedAt: number,
    onProgress?: V1ProgressFn,
  ): Promise<boolean> {
    const lastSync: number = await this.db.getLastSyncAt();
    const delta: DeviceSyncPayload =
      await collectDeviceSnapshot(this.db, localDeviceId, lastSync, this.clock());
    const changed: number = countChanges(delta);

    if (options.receiveOnly) {
      if (counts.applied <= 0) {
        // Receive-only with nothing applied has nothing new to publish, and the
        // existing snapshot already describes this device.
        return false;
      }
      // Still publish the merged result, so a peer sees the outcome of this pass
      // rather than having to re-derive it.
      this.report(onProgress, '上传合并后的快照...', 0, 0);
      const merged: DeviceSyncPayload =
        await collectDeviceSnapshot(this.db, localDeviceId, 0, this.clock());
      const wrote: boolean = await this.saveDeviceSnapshot(merged);
      counts.tablesUploaded = Object.keys(merged.tables).length;
      return wrote;
    }

    const snapshot: DeviceSyncPayload =
      await collectDeviceSnapshot(this.db, localDeviceId, 0, this.clock());
    let shouldPush: boolean = changed > 0 || counts.applied > 0;
    if (!shouldPush) {
      // Nothing local changed and nothing was merged, but the server must still
      // hold a full snapshot so a device that syncs later can bootstrap from this
      // one even if this device is never synced again. An absent or stale copy is
      // refreshed; the 5-minute floor keeps a rapid sequence of manual syncs from
      // re-uploading the library each time.
      const existing: ParsedDeviceSnapshot | undefined =
        await this.loadSnapshot(v1DevicePath(localDeviceId));
      const age: number = existing === undefined ? -1 : startedAt - existing.timestamp;
      shouldPush = existing === undefined || age > SNAPSHOT_MAX_AGE_MS;
    }
    if (!shouldPush) {
      return false;
    }
    this.report(onProgress, `上传 ${countChanges(snapshot)} 条变更...`, 0, 0);
    const wrote: boolean = await this.saveDeviceSnapshot(snapshot);
    counts.tablesUploaded = Object.keys(snapshot.tables).length;
    return wrote;
  }

  /** The index refusal for this pass, empty when writing is allowed. */
  async indexRefusal(): Promise<string> {
    const index: V1IndexLoad = await this.loadIndex();
    if (isWritableV1IndexKind(index.kind)) {
      return '';
    }
    return indexRefusalMessage(index.kind, index.record);
  }

  private report(
    onProgress: V1ProgressFn | undefined,
    message: string,
    completed: number,
    total: number,
  ): void {
    if (onProgress === undefined) {
      return;
    }
    const progress: V1Progress = { message: message, completed: completed, total: total };
    onProgress(progress);
  }
}
