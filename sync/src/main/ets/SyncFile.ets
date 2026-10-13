/**
 * Per-book sync file format and merge rules.
 *
 * Ported from ReadAny `packages/core/src/sync/per-book-sync.ts`
 * (`BookSyncFile`, `mergeItemRows`, `mergeDeletedMap`, `buildBookFile`).
 *
 * Wire format, at `/readany/sync/books/{bookId}.json`:
 *
 *     { schemaVersion: 1, bookId, book, highlights[], notes[], bookmarks[],
 *       deleted?: { highlights?: {id: deletedAt}, notes?: {...}, bookmarks?: {...} },
 *       writerDeviceId, updatedAt }
 *
 * `book`, `highlights`, `notes` and `bookmarks` are rows keyed by *SQLite column
 * names* — there is no camelCase translation on the wire, so the mappers in the
 * data layer are responsible for producing and consuming that shape.
 */

import { FILE_SCHEMA_VERSION } from './SyncConstants';

/**
 * One row as it travels on the wire.
 *
 * Only the fields every synced table has are declared; the rest of a row is
 * carried by the underlying record and read through a `FieldReader`. Declaring a
 * full interface per table would duplicate the schema here for no benefit.
 *
 * This is a plain interface rather than extending `FieldReader`: that type is now
 * a class (it has to be, so implementations can be crossed between modules) and
 * ArkTS forbids an interface extending a class.
 */
export interface SyncRow {
  /** The row's primary key, always an id column in the synced tables. */
  id: string;
  /** Row timestamp used for last-write-wins. */
  updatedAt: number;
}

/** `annotation table name -> (row id -> deletion timestamp)`. */
export type DeletedMaps = Map<string, Map<string, number>>;

/** A parsed per-book sync file. */
export interface BookSyncFile {
  schemaVersion: number;
  bookId: string;
  book: Record<string, Object>;
  highlights: Record<string, Object>[];
  notes: Record<string, Object>[];
  bookmarks: Record<string, Object>[];
  deleted: DeletedMaps;
  writerDeviceId: string;
  updatedAt: number;
}

/** Classification of a remote index document. */
export enum IndexKind {
  /** A schema-v2 per-book index. */
  PER_BOOK = 'per-book',
  /**
   * The pre-per-book `index.json`: `{version, updatedAt, devices}`.
   *
   * This is the document that actually sits at `/readany/sync/index.json` after any
   * sync run by a client older than the per-book rewrite. ReadAny's writer for it is
   * `saveDeviceSnapshot` (simple-sync.ts:700-729) and its type is `DeviceSyncIndex`
   * (simple-sync.ts:75-85). It shares the path with the per-book index, so it must be
   * recognised and refused — publishing a per-book index over it hides every book it
   * describes.
   */
  LEGACY_DEVICE_INDEX = 'legacy-device-index',
  /** A `DeviceSyncPayload` — the per-device snapshot body, written to `device-<id>.json`. */
  LEGACY_DEVICE = 'legacy-device',
  /** Absent, empty or unrecognisable. */
  UNKNOWN = 'unknown',
}

/** `index.json` `schemaVersion` for the per-book layout. */
export interface ProfileSyncFile {
  schemaVersion: number;
  /**
   * Raw wire rows, keyed by the table's own column names.
   *
   * Loose objects rather than `SyncRow`: a profile table's columns are the table's
   * business, and narrowing them here would mean the sync layer had to know the shape
   * of every profile table it carries. The merge reads `id` and `updated_at` through
   * `FieldReader`, so it needs no more than that.
   */
  rows: Record<string, Object>[];
  /** `id` → `deletedAt`. Absent when nothing was deleted. */
  deleted: Map<string, number>;
  updatedAt: number;
}

export function isPerBookIndex(record: Record<string, Object> | undefined): boolean {
  if (record === undefined) {
    return false;
  }
  const version: Object | undefined = record['schemaVersion'];
  if (version !== 2) {
    return false;
  }
  const books: Object | undefined = record['books'];
  const threads: Object | undefined = record['threads'];
  return books !== undefined && books !== null && typeof books === 'object'
    && threads !== undefined && threads !== null && typeof threads === 'object';
}

/**
 * True when the document is ReadAny's **legacy `index.json`**.
 *
 * Ported from `DeviceSyncIndex` (ReadAny `simple-sync.ts:75-85`), written by
 * `saveDeviceSnapshot` (`:700-729`) to the *same path* the per-book protocol later
 * claimed. Shape:
 *
 *     { version: 1, updatedAt: <number>, devices: { <deviceId>: { path, timestamp } } }
 *
 * It has no `schemaVersion`, so it is not a per-book index, and it has no
 * top-level `deviceId`/`timestamp`/`tables`, so `isLegacyDeviceIndex` does not
 * match it either. That is the whole defect being fixed here: the one document that
 * really is at this path used to fall through to `UNKNOWN`, and `UNKNOWN` used to
 * mean "empty", and empty meant "overwrite".
 *
 * Every device entry must look like `{path: string, timestamp: number}`. A document
 * whose `devices` holds something else is not positively this format and falls
 * through to `UNKNOWN`, which is refused too — so a stricter match here can only
 * change which message the user sees, never whether the file is protected.
 */
export function isLegacyIndex(record: Record<string, Object> | undefined): boolean {
  if (record === undefined) {
    return false;
  }
  const version: Object | undefined = record['version'];
  if (typeof version !== 'number' || Number.isNaN(version)) {
    return false;
  }
  const devices: Object | undefined = record['devices'];
  if (devices === undefined || devices === null || typeof devices !== 'object'
    || Array.isArray(devices)) {
    return false;
  }
  const map: Record<string, Object> = devices as Record<string, Object>;
  for (const deviceId of Object.keys(map)) {
    const entry: Object = map[deviceId];
    if (entry === undefined || entry === null || typeof entry !== 'object'
      || Array.isArray(entry)) {
      return false;
    }
    const path: Object | undefined = (entry as Record<string, Object>)['path'];
    const timestamp: Object | undefined = (entry as Record<string, Object>)['timestamp'];
    if (typeof path !== 'string' || typeof timestamp !== 'number') {
      return false;
    }
  }
  return true;
}

/**
 * True when the document looks like a `DeviceSyncPayload`.
 *
 * That payload lives at `device-<id>.json`, not at `index.json` — it is classified
 * separately so an error message can name what was actually found. This predicate
 * was previously used as the `index.json` guard; it never matched the document that
 * really sits there, which is why the guard it fed was unreachable.
 */
export function isLegacyDeviceIndex(record: Record<string, Object> | undefined): boolean {
  if (record === undefined) {
    return false;
  }
  const deviceId: Object | undefined = record['deviceId'];
  const timestamp: Object | undefined = record['timestamp'];
  const tables: Object | undefined = record['tables'];
  return typeof deviceId === 'string'
    && typeof timestamp === 'number'
    && tables !== undefined && tables !== null && typeof tables === 'object';
}

/** `threads` map of a per-book index, or an empty record when it carries none. */
export function threadsCellOf(record: Record<string, Object>): Record<string, Object> {
  const value: Object | undefined = record['threads'];
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, Object>;
}

/**
 * Classify an index document.
 *
 * A per-book index is tested first: it is the only shape this client may write.
 */
export function classifyIndex(record: Record<string, Object> | undefined): IndexKind {
  if (isPerBookIndex(record)) {
    return IndexKind.PER_BOOK;
  }
  if (isLegacyIndex(record)) {
    return IndexKind.LEGACY_DEVICE_INDEX;
  }
  if (isLegacyDeviceIndex(record)) {
    return IndexKind.LEGACY_DEVICE;
  }
  return IndexKind.UNKNOWN;
}

/**
 * True for the two pre-per-book documents that share `index.json`'s history.
 *
 * Both are refused, for the same reason: this client does not implement their
 * importer, and publishing a per-book index on top of either destroys the only
 * record of what the server holds.
 */
export function isLegacyIndexKind(kind: IndexKind): boolean {
  return kind === IndexKind.LEGACY_DEVICE_INDEX || kind === IndexKind.LEGACY_DEVICE;
}

/** Top-level field names of a document, for an error message. */
export function recordShapeOf(record: Record<string, Object>): string {
  const keys: string[] = Object.keys(record);
  return keys.length > 0 ? keys.join(', ') : '(no fields)';
}

/**
 * Read a JSON object-of-numbers into a map.
 *
 * Non-numeric entries are dropped rather than coerced: a malformed `deletedAt`
 * would otherwise become `NaN` and make every tombstone comparison false, which
 * fails open (nothing gets deleted).
 */
export function toNumberMap(value: Object | undefined): Map<string, number> {
  const out: Map<string, number> = new Map<string, number>();
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return out;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (const key of keys) {
    const raw: Object = record[key];
    if (typeof raw === 'number' && !Number.isNaN(raw)) {
      out.set(key, raw);
    }
  }
  return out;
}

/** Read the nested `deleted` map of a book file. */
export function toDeletedMaps(value: Object | undefined): DeletedMaps {
  const out: DeletedMaps = new Map<string, Map<string, number>>();
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return out;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  for (const table of Object.keys(record)) {
    const map: Map<string, number> = toNumberMap(record[table]);
    if (map.size > 0) {
      out.set(table, map);
    }
  }
  return out;
}

/**
 * Per-id max union of two deletion maps for one annotation table.
 *
 * Named distinctly from `SyncIndex.mergeDeletedMap`, which unions a single
 * `id -> timestamp` map: this one operates on one table of the nested per-book
 * `deleted` tree.
 */
export function mergeDeletedMapTree(
  remote: Map<string, number> | undefined,
  ours: Map<string, number> | undefined,
): Map<string, number> {
  const merged: Map<string, number> = new Map<string, number>();
  if (remote !== undefined) {
    remote.forEach((value: number, key: string): void => {
      merged.set(key, value);
    });
  }
  if (ours !== undefined) {
    ours.forEach((value: number, key: string): void => {
      const existing: number | undefined = merged.get(key);
      merged.set(key, Math.max(existing ?? 0, value));
    });
  }
  return merged;
}

/**
 * Merge two row collections by id, taking the row with the newer timestamp.
 *
 * Ported from `mergeItemRows`. Rows present only on one side are kept, which is
 * what makes this a union rather than a choice of winner.
 */
export function mergeSyncRows(
  localRows: SyncRow[],
  remoteRows: SyncRow[] | undefined,
  timestampKey: string,
): SyncRow[] {
  if (remoteRows === undefined || remoteRows.length === 0) {
    return localRows;
  }
  const byId: Map<string, SyncRow> = new Map<string, SyncRow>();
  for (const row of localRows) {
    byId.set(row.id, row);
  }
  for (const row of remoteRows) {
    const local: SyncRow | undefined = byId.get(row.id);
    if (local === undefined) {
      byId.set(row.id, row);
      continue;
    }
    if (row.updatedAt > local.updatedAt) {
      byId.set(row.id, row);
    }
  }
  const out: SyncRow[] = [];
  byId.forEach((row: SyncRow): void => {
    out.push(row);
  });
  return out;
}

/**
 * Union two `Record<string, Object>` maps of rows, keyed by id, newest wins.
 *
 * The wire rows are loose objects rather than `SyncRow`, so this is the variant
 * `buildBookFile` needs. Timestamps are read through `FieldReader` so a row whose
 * timestamp is missing or non-numeric is treated as oldest rather than throwing.
 */
export function mergeRecordRows(
  localRows: Record<string, Object>[],
  remoteRows: Record<string, Object>[] | undefined,
  timestampKey: string,
): Record<string, Object>[] {
  if (remoteRows === undefined || remoteRows.length === 0) {
    return localRows;
  }
  const byId: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();
  for (const row of localRows) {
    byId.set(rowIdOf(row), row);
  }
  for (const row of remoteRows) {
    const id: string = rowIdOf(row);
    const local: Record<string, Object> | undefined = byId.get(id);
    if (local === undefined) {
      byId.set(id, row);
      continue;
    }
    if (rowTimestampOf(row, timestampKey) > rowTimestampOf(local, timestampKey)) {
      byId.set(id, row);
    }
  }
  const out: Record<string, Object>[] = [];
  byId.forEach((row: Record<string, Object>): void => {
    out.push(row);
  });
  return out;
}

/** The `id` cell of a wire row, or an empty string when absent. */
export function rowIdOf(row: Record<string, Object>): string {
  const value: Object | undefined = row['id'];
  if (value === undefined || value === null) {
    return '';
  }
  return typeof value === 'string' ? value : String(value);
}

/**
 * The timestamp cell of a wire row.
 *
 * Accepts a number or a numeric string, and returns 0 for anything else, so a
 * malformed row loses the comparison instead of poisoning it with `NaN`.
 */
export function rowTimestampOf(row: Record<string, Object>, key: string): number {
  const value: Object | undefined = row[key];
  if (value === undefined || value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    return Number.isNaN(value) ? 0 : value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/**
 * Build the file to upload for one book.
 *
 * Ported from `buildBookFile`. Every collection is the *union* of local and
 * remote, newest row per id, and the deletion maps are unioned the same way. That
 * is what makes the file a merge rather than an overwrite: a peer's annotation
 * that this device has never seen survives the round trip.
 */
/**
 * Build a profile file for upload.
 *
 * Structurally identical to a book file — `schemaVersion: 1`, `rows`, an optional
 * `deleted` map, `updatedAt` — so `mergeRecordRows` and the deleted-map helpers apply
 * unchanged. Only the row shape differs, and that is data rather than schema.
 *
 * `updated_at` is the timestamp the merge compares. `tags` and `book_tags` are not
 * built here: they have no such column, so there is nothing to compare and no correct
 * rule to apply.
 */
export function buildProfileFile(
  rows: Record<string, Object>[],
  deleted: Map<string, number>,
  now: number,
): ProfileSyncFile {
  return {
    schemaVersion: FILE_SCHEMA_VERSION,
    rows: rows,
    deleted: deleted,
    updatedAt: now,
  };
}

export function buildBookFile(
  bookId: string,
  localBook: Record<string, Object>,
  localHighlights: Record<string, Object>[],
  localNotes: Record<string, Object>[],
  localBookmarks: Record<string, Object>[],
  localDeleted: DeletedMaps,
  remote: BookSyncFile | undefined,
  deviceId: string,
  now: number,
): BookSyncFile {
  const deleted: DeletedMaps = new Map<string, Map<string, number>>();
  for (const table of ['highlights', 'notes', 'bookmarks']) {
    const merged: Map<string, number> = mergeDeletedMapTree(
      remote !== undefined ? remote.deleted.get(table) : undefined,
      localDeleted.get(table),
    );
    if (merged.size > 0) {
      deleted.set(table, merged);
    }
  }

  const remoteBook: Record<string, Object>[] | undefined =
    remote !== undefined ? [remote.book] : undefined;

  return {
    schemaVersion: FILE_SCHEMA_VERSION,
    bookId: bookId,
    book: mergeRecordRows([localBook], remoteBook, 'updated_at')[0],
    highlights: mergeRecordRows(localHighlights, remote !== undefined ? remote.highlights : undefined, 'updated_at'),
    notes: mergeRecordRows(localNotes, remote !== undefined ? remote.notes : undefined, 'updated_at'),
    bookmarks: mergeRecordRows(localBookmarks, remote !== undefined ? remote.bookmarks : undefined, 'updated_at'),
    deleted: deleted,
    writerDeviceId: deviceId,
    updatedAt: now,
  };
}

/**
 * Serialize a deletion map tree to the wire shape.
 *
 * Built by assignment on an empty record rather than an object literal, because
 * ArkTS will not accept a literal as the value of `Record<string, Object>`
 * (`arkts-no-untyped-obj-literals`).
 */
export function deletedMapsToWire(deleted: DeletedMaps): Record<string, Object> {
  const out: Record<string, Object> = {};
  deleted.forEach((map: Map<string, number>, table: string): void => {
    const inner: Record<string, Object> = {};
    map.forEach((value: number, id: string): void => {
      inner[id] = value;
    });
    out[table] = inner;
  });
  return out;
}
