/**
 * InkBoat sync layer — WebDAV client and per-book sync engine.
 *
 * Wire-compatible with ReadAny: `/readany/sync/index.json` (per-field max
 * merge) + `/readany/sync/books/{bookId}.json` (row + annotations + deleted
 * map) + `/readany/data/books/{sanitized-title}-{bookId}/` (binaries) +
 * `/readany/data/file-manifest.json`.
 */

// --- protocol constants -----------------------------------------------------
export {
  ANNOTATION_TABLES,
  BOOK_EXTENSIONS,
  BOOK_LOCAL_EXCLUDED_COLUMNS,
  COVER_EXTENSIONS,
  DEFAULT_REMOTE_ROOT,
  FILE_SCHEMA_VERSION,
  INDEX_SCHEMA_VERSION,
  labelForMode,
  MAX_FUTURE_TOMBSTONE_SKEW_MS,
  policyForMode,
  REMOTE_BOOKS_ROOT,
  REMOTE_COVERS,
  REMOTE_DATA,
  REMOTE_FILES,
  REMOTE_FILE_MANIFEST,
  REMOTE_ROOT,
  REMOTE_SYNC,
  REMOTE_SYNC_BOOKS,
  REMOTE_SYNC_INDEX,
  SYNC_CONFIG_KEY_WEBDAV,
  SYNC_SECRET_KEY_WEBDAV,
  SyncMode,
  timestampColumnFor,
} from './src/main/ets/SyncConstants';
export type { SyncPolicy } from './src/main/ets/SyncConstants';

export {
  jsonExcerptOf,
  JsonDocument,
  JsonReadOutcome,
  parseJsonRecord,
  readJsonDocument,
  utf8Decode,
  utf8Encode,
} from './src/main/ets/ByteText';

// --- remote naming ----------------------------------------------------------
export {
  buildBookFolderName,
  buildBookRemoteCover,
  buildBookRemoteDir,
  buildBookRemoteFile,
  extensionOf,
  isBookFileName,
  isCoverFileName,
  parseBookFolderName,
  sanitizeBookTitleForFs,
} from './src/main/ets/RemoteNaming';

// --- remote paths -----------------------------------------------------------
export {
  baseUrlAlreadyIncludesRemoteRoot,
  buildRequestUrl,
  effectiveRemoteRoot,
  encodePathSegments,
  filenameFromPath,
  isDirectChildPath,
  joinLogicalPath,
  normalizeWebDavPath,
  pathnameOf,
  resolveRemotePath,
  safeDecode,
  sanitizeWebDavRemoteRoot,
  sanitizeWebDavUrl,
  stripControlChars,
  toCollectionPath,
  toCollectionRequestPath,
} from './src/main/ets/RemotePaths';
export type { RemoteRootConfig } from './src/main/ets/RemotePaths';

// --- conflict resolution ----------------------------------------------------
export {
  isPlausibleTombstone,
  localRecordState,
  normalizeDeletedAt,
  shouldApplyRemoteRecord,
  shouldApplyTombstone,
} from './src/main/ets/ShouldApply';
export type { FieldReader, LocalRecordState } from './src/main/ets/ShouldApply';

// --- index ------------------------------------------------------------------
export {
  bookEntry,
  emptyBookEntry,
  emptyIndex,
  emptyThreadEntry,
  isBookEntryCovered,
  isRemoteBookDeleted,
  mergeBookEntry,
  mergeDeletedMap,
  mergeIndex,
  mergeThreadEntry,
  NO_MARKER,
  threadEntry,
} from './src/main/ets/SyncIndex';
export type { BookIndexEntry, SyncIndexFile, ThreadIndexEntry } from './src/main/ets/SyncIndex';

// --- per-book file format ---------------------------------------------------
export {
  buildBookFile,
  classifyIndex,
  deletedMapsToWire,
  IndexKind,
  isLegacyDeviceIndex,
  isLegacyIndex,
  isLegacyIndexKind,
  isPerBookIndex,
  mergeDeletedMapTree,
  mergeRecordRows,
  mergeSyncRows,
  recordShapeOf,
  rowIdOf,
  rowTimestampOf,
  threadsCellOf,
  toDeletedMaps,
  toNumberMap,
} from './src/main/ets/SyncFile';
export type { BookSyncFile, DeletedMaps, SyncRow } from './src/main/ets/SyncFile';

// --- PROPFIND parsing -------------------------------------------------------
export {
  extractTagContent,
  parsePropfindBlock,
  parsePropfindDetailed,
  parsePropfindResponse,
  splitResponseBlocks,
} from './src/main/ets/PropfindParser';
export type { ParsedListing, PropfindParseReport } from './src/main/ets/PropfindParser';

// --- transport --------------------------------------------------------------
export {
  clampConcurrency,
  defaultWebDavConfig,
  DEFAULT_CONCURRENCY,
  DEFAULT_SYNC_INTERVAL_MINS,
  idleProgress,
  MAX_CONCURRENCY,
  MIN_CONCURRENCY,
  SyncPhase,
} from './src/main/ets/WebDavTypes';
export type {
  RemoteFile,
  RemoteResource,
  SyncProgress,
  SyncResult,
  WebDavConfig,
} from './src/main/ets/WebDavTypes';
export {
  HarmonyHttpTransport,
  parentOf,
  TRANSFER_TIMEOUT_MS,
  WebDavClient,
} from './src/main/ets/WebDavClient';
export type { DavResponse, HttpTransport } from './src/main/ets/WebDavClient';


export {
  DEFAULT_PROBE_URL,
  formatProbeResult,
  probeCustomMethod,
} from './src/main/ets/MethodProbe';
export type { ProbeResult, ProbeStep } from './src/main/ets/MethodProbe';
// --- profile layer (book_groups) --------------------------------------------
export {
  PROFILE_BOOK_GROUPS,
  PROFILE_TABLES,
  REMOTE_PROFILE,
} from './src/main/ets/SyncConstants';
export { remoteProfilePath } from './src/main/ets/RemotePaths';
// `mergeDeletedMapTree` and `mergeRecordRows` are already exported above, and the
// profile layer reuses them unchanged — re-exporting them here was a duplicate.
export { buildProfileFile } from './src/main/ets/SyncFile';
export type { ProfileSyncFile } from './src/main/ets/SyncFile';