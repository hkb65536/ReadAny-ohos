/**
 * InkBoat data layer — RDBStore schema, repositories and the sync engine.
 *
 * Repositories take an open `Database` and are stateless; the caller owns the
 * connection so one store is shared by the UI and the sync engine instead of each
 * opening its own.
 */

// --- schema -----------------------------------------------------------------
export {
  ANNOTATION_TABLES,
  CURRENT_SCHEMA_VERSION,
  META_DEVICE_ID,
  META_LAST_SYNC_AT,
  SCHEMA_MIGRATIONS,
  SCHEMA_STATEMENTS,
  SYNC_STATUS_DOWNLOADING,
  SYNC_STATUS_LOCAL,
  SYNC_STATUS_REMOTE,
  SYNC_TABLES,
} from './src/main/ets/Schema';
export type { SchemaMigration } from './src/main/ets/Schema';

// --- connection -------------------------------------------------------------
export { openDatabase, Rdb } from './src/main/ets/Rdb';
export type { BindValue, Row } from './src/main/ets/Rdb';
export { Database } from './src/main/ets/Database';

// --- shared record access ---------------------------------------------------
export { jsonReader, sqlReader } from './src/main/ets/RecordReader';

// --- domain types -----------------------------------------------------------
export { HIGHLIGHT_COLORS, HIGHLIGHT_COLOR_HEX } from './src/main/ets/Types';
export type {
  Book,
  BookFormat,
  Bookmark,
  BookWithCounts,
  Highlight,
  HighlightColor,
  Note,
  SyncStatus,
} from './src/main/ets/Types';

// --- mappers ----------------------------------------------------------------
export {
  BOOK_COLUMNS,
  BOOKMARK_COLUMNS,
  HIGHLIGHT_COLUMNS,
  NOTE_COLUMNS,
  bookToSyncRecord,
  bookToSyncRecordForUpload,
  bookValues,
  bookmarkToSyncRecord,
  bookmarkValues,
  highlightToSyncRecord,
  highlightValues,
  noteToSyncRecord,
  noteValues,
  parseJsonArray,
  toBook,
  toBookmark,
  toHighlight,
  toNote,
} from './src/main/ets/Records';

// --- repositories -----------------------------------------------------------
export {
  Books,
  BookSort,
  defaultLibraryQuery,
  isCanonicalCoverPath,
  isCustomCoverPath,
} from './src/main/ets/Books';
export type { AnnotationCounts, LibraryQuery } from './src/main/ets/Books';
export { Bookmarks, sortByPosition } from './src/main/ets/Bookmarks';
export { Highlights } from './src/main/ets/Highlights';
export { Notes } from './src/main/ets/Notes';

// --- sync engine ------------------------------------------------------------
export {
  emptyMarkers,
  emptyTransferCounts,
  mergeMarkers,
  progressFromV1,
  SyncEngine,
} from './src/main/ets/SyncEngine';
export type {
  BookMarkers,
  BookTransferCounts,
  SyncProgress,
  SyncProgressFn,
  ThreadMarkers,
} from './src/main/ets/SyncEngine';

// --- v1 per-device protocol (interop with ReadAny v1.3.6) -------------------
export {
  applyDeviceSnapshot,
  bookFilePathForExtension,
  canonicalBookCoverPath,
  canonicalBookFilePath,
  classifyV1Index,
  collectDeviceSnapshot,
  collectTableChanges,
  countChanges,
  defaultV1SyncOptions,
  emptyV1FileSyncCounts,
  emptyV1SyncCounts,
  indexRefusalMessage,
  indexToWire,
  // `isCanonicalCoverPath` and `isCustomCoverPath` are already exported from
  // `./Books` below, so the v1 engine's identical pair is not re-exported here.
  isConvertedSourceFormat,
  isWritableV1IndexKind,
  localizeSyncedBookRecord,
  parseDeviceSnapshot,
  payloadToWire,
  preserveLocalCustomBookCover,
  RdbRecordWriter,
  readDeviceEntries,
  SyncV1Engine,
  unjustifiedDeletions,
  v1DevicePath,
  v1TableConfig,
  V1_INDEX_PATH,
  V1_INDEX_VERSION,
  V1_SYNC_DIR,
  V1_SYNC_TABLES,
  V1IndexKind,
} from './src/main/ets/SyncV1';
export type {
  ChangesetViolation,
  DeviceIndexEntry,
  DeviceSyncIndex,
  DeviceSyncPayload,
  ParsedDeviceSnapshot,
  TableChangeset,
  V1IndexLoad,
  V1LocalState,
  V1Progress,
  V1ProgressFn,
  V1RecordWriter,
  V1RemoteDevice,
  V1SyncCounts,
  V1SyncOptions,
  V1SyncResult,
  V1TableConfig,
  WireRow,
} from './src/main/ets/SyncV1';

// --- the v1 file phase (book files, covers, the remote manifest) ------------
// Deliberately exported so the settings screen and a future on-demand download can reach
// the same phase the pass uses, rather than growing a second implementation of the rules.
export { V1FilePhase } from './src/main/ets/V1FilePhase';
export type { V1FileCounts, V1FileProgressFn, V1FileRunner } from './src/main/ets/BinarySync';

// --- protocol routing (v1 vs v2, decided from the remote index) -------------
export {
  decideProtocol,
  describeProtocol,
  describeV1Result,
  ProtocolDecision,
  protocolForV1Kind,
  protocolRefusalError,
  SyncProtocol,
  userInitiatedV1Options,
  v1OptionsForMode,
} from './src/main/ets/SyncRouter';

// --- configuration and credentials ------------------------------------------
export {
  CREDENTIAL_WEBDAV_PASSWORD,
  CredentialStore,
} from './src/main/ets/CredentialStore';
export { SyncConfigStore } from './src/main/ets/SyncConfigStore';
export type { StoredSyncConfig } from './src/main/ets/SyncConfigStore';
export { isSyncAllowedNow, readNetworkState } from './src/main/ets/NetworkStatus';
export type { NetworkState } from './src/main/ets/NetworkStatus';
export { SyncService, SyncRunStatus } from './src/main/ets/SyncService';
export type { SyncObserver, SyncProgressCallback, SyncSnapshot } from './src/main/ets/SyncService';

// --- binary files -----------------------------------------------------------
export {
  defaultBinaryOptions,
  emptyBinaryCounts,
  emptyManifest,
  emptyManifestEntry,
  isCustomCoverFileName,
  manifestCoversAll,
  manifestFromWire,
  manifestPath,
  manifestToWire,
  planBinarySync,
  remoteFolderName,
  remoteStem,
  TransferKind,
  unknownRemoteState,
} from './src/main/ets/BinarySync';
export type {
  BinarySyncCounts,
  BinarySyncOptions,
  BinarySyncPlan,
  BookBinaryInput,
  LocalBinaryState,
  ManifestEntry,
  RemoteBinaryState,
  RemoteFileManifest,
  TransferTask,
} from './src/main/ets/BinarySync';
export { FileStorage } from './src/main/ets/FileStorage';
export type { FileHasher, LocalFileInfo } from './src/main/ets/FileStorage';
export { hashFileSha256, toHex } from './src/main/ets/FileHasher';
export { FileStorageRunner } from './src/main/ets/FileStorageRunner';
// --- book import ------------------------------------------------------------
export { BookImporter, DirectoryEpubSource } from './src/main/ets/BookImporter';
export type { ImportResult } from './src/main/ets/BookImporter';
export {
  decodeEntities,
  decodeUtf8,
  emptyEpubMetadata,
  parseEpub,
} from './src/main/ets/EpubMetadata';
export type { EpubMetadata, EpubSource } from './src/main/ets/EpubMetadata';

// --- TXT -> EPUB conversion -------------------------------------------------
export { TxtToEpubConverter } from './src/main/ets/TxtToEpub';
export type { TxtConvertOptions, TxtConvertResult } from './src/main/ets/TxtToEpub';
export { buildStoreOnlyZip, crc32Of, StoreOnlyZipWriter } from './src/main/ets/StoreOnlyZip';
export type { ZipEntry, ZipRecord } from './src/main/ets/StoreOnlyZip';

// --- reader state -----------------------------------------------------------
// `dayReaderSettings` / `nightReaderSettings` are gone with the reader's own colour
// fields: appearance is derived from the application theme by
// `entry/src/main/ets/theme/Theme.ets`'s `readerAppearance`, which is the one owner.
export {
  clampFontSize,
  clampLineHeight,
  copySettings,
  defaultReaderSettings,
  emptyPosition,
  hasPosition,
  hasSyncedPosition,
  MAX_FONT_SIZE,
  MAX_LINE_HEIGHT,
  MIN_FONT_SIZE,
  MIN_LINE_HEIGHT,
  NO_POSITION_SPINE,
  ReaderStore,
  resolveOpenPosition,
} from './src/main/ets/ReaderStore';
export type { ReaderSettings, ReadingPosition } from './src/main/ets/ReaderStore';
// --- shelf groups (profile sync) --------------------------------------------
export { BookGroups, BOOK_GROUPS_TABLE, BOOK_GROUP_TIMESTAMP_KEY } from './src/main/ets/BookGroups';
export { BOOK_GROUP_COLUMNS } from './src/main/ets/Types';
export type { BookGroup } from './src/main/ets/Types';
export {
  bookGroupFromWire,
  bookGroupToSyncRecord,
  toBookGroup,
} from './src/main/ets/Records';