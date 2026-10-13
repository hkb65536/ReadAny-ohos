/**
 * WebDAV transport types.
 *
 * Ported from ReadAny `packages/core/src/sync/sync-types.ts` (`DavResource`,
 * `SyncProgress`) and `sync-backend.ts` (`RemoteFile`, `WebDavConfig`).
 */

/** One entry from a PROPFIND multistatus response. */
export interface RemoteResource {
  /** Normalized, decoded absolute path on the server. */
  href: string;
  /** Last path segment. */
  name: string;
  /** True for a WebDAV collection (directory). */
  isCollection: boolean;
  /** `getcontentlength`, or 0 when the server did not report it. */
  contentLength: number;
  /** Raw `getlastmodified` header value, or empty. */
  lastModified: string;
  /** `getetag` with surrounding quotes stripped, or empty. */
  etag: string;
}

/** A listing entry as the sync engine sees it (logical paths, not href). */
export interface RemoteFile {
  name: string;
  /** Logical protocol path, suitable for passing back to `get`/`put`. */
  path: string;
  size: number;
  /** Epoch milliseconds, or 0 when unknown. */
  lastModified: number;
  isDirectory: boolean;
}

/** WebDAV connection settings. The password is never stored here. */
export interface WebDavConfig {
  /** Base URL exactly as the user typed it, e.g. `https://host/dav`. */
  url: string;
  username: string;
  /** Overrides the default `readany` root; empty means default. */
  remoteRoot: string;
  /** Allow plain HTTP and self-signed certificates. Defaults to false. */
  allowInsecure: boolean;
  /** Sync automatically on start-up / foreground. */
  autoSync: boolean;
  /** Interval in minutes for periodic sync while the app is in the foreground. */
  syncIntervalMins: number;
  /** Only sync while on Wi-Fi. */
  wifiOnly: boolean;
  /** How many files to transfer concurrently (1-6). */
  concurrency: number;
}

/** Defaults matching the existing clients. */
export const DEFAULT_SYNC_INTERVAL_MINS: number = 30;
export const DEFAULT_CONCURRENCY: number = 2;
export const MIN_CONCURRENCY: number = 1;
export const MAX_CONCURRENCY: number = 6;

export function defaultWebDavConfig(): WebDavConfig {
  return {
    url: '',
    username: '',
    remoteRoot: '',
    allowInsecure: false,
    autoSync: false,
    syncIntervalMins: DEFAULT_SYNC_INTERVAL_MINS,
    wifiOnly: false,
    concurrency: DEFAULT_CONCURRENCY,
  };
}

/** Clamp a user-supplied concurrency into the supported range. */
export function clampConcurrency(value: number): number {
  if (Number.isNaN(value) || value < MIN_CONCURRENCY) {
    return MIN_CONCURRENCY;
  }
  if (value > MAX_CONCURRENCY) {
    return MAX_CONCURRENCY;
  }
  return Math.floor(value);
}

/** Sync engine phase, used to drive progress UI. */
export enum SyncPhase {
  IDLE = 'idle',
  CHECKING = 'checking',
  PULLING = 'pulling',
  PUSHING = 'pushing',
  FILES = 'files',
  ERROR = 'error',
}

/** Progress report handed to the UI. */
export interface SyncProgress {
  phase: SyncPhase;
  /** Human-readable status, already localized by the caller. */
  message: string;
  completedFiles: number;
  totalFiles: number;
  /** Remote path currently being transferred, or empty. */
  currentFile: string;
}

export function idleProgress(): SyncProgress {
  return {
    phase: SyncPhase.IDLE,
    message: '',
    completedFiles: 0,
    totalFiles: 0,
    currentFile: '',
  };
}

/** Outcome of one sync pass. */
export interface SyncResult {
  success: boolean;
  booksPulled: number;
  booksPushed: number;
  filesUploaded: number;
  filesDownloaded: number;
  filesFailed: number;
  durationMs: number;
  /** Error message when `success` is false. */
  error: string;
}
