/**
 * Remote path resolution.
 *
 * Ported from ReadAny `packages/core/src/sync/webdav-backend.ts`
 * (`resolvePath`, `baseUrlAlreadyIncludesRemoteRoot`, `joinLogicalPath`) plus the
 * sanitizers from `webdav-client.ts`.
 *
 * The subtlety worth preserving: a user may configure the base URL either as
 * `https://host/dav` (and let `remoteRoot` create `/readany` underneath) or as
 * `https://host/dav/readany` (already including the root). Both must resolve to
 * the same server-side location, and neither may produce `/readany/readany`.
 */

import { url } from '@kit.ArkTS';
import { DEFAULT_REMOTE_ROOT, REMOTE_PROFILE, REMOTE_ROOT } from './SyncConstants';

/**
 * Remote path of a profile table's file.
 *
 * One file per table, matching the reference layout: `profile/{table}.json`.
 */
export function remoteProfilePath(table: string): string {
  return `${REMOTE_PROFILE}/${table}.json`;
}

const CONTROL_OR_DEL: RegExp =
  new RegExp(`[${String.fromCharCode(0)}-${String.fromCharCode(31)}${String.fromCharCode(127)}]`, 'g');
const LEADING_TRAILING_SLASHES: RegExp = /^\/+|\/+$/g;
const MULTI_SLASH: RegExp = /\/{2,}/g;

/** Strip control characters from a user-supplied value. */
export function stripControlChars(value: string): string {
  return value.replace(CONTROL_OR_DEL, '');
}

/** Normalize a base URL: strip control characters, trim, drop trailing slashes. */
export function sanitizeWebDavUrl(url: string): string {
  return stripControlChars(url).trim().replace(/\/+$/, '');
}

/**
 * Normalize `remoteRoot`: no control characters, no surrounding or doubled
 * slashes. May return an empty string, which callers treat as "use the default".
 */
export function sanitizeWebDavRemoteRoot(remoteRoot: string): string {
  return stripControlChars(remoteRoot)
    .trim()
    .replace(LEADING_TRAILING_SLASHES, '')
    .replace(MULTI_SLASH, '/');
}

/**
 * Path component of a URL.
 *
 * ArkTS has no global `URL`, so `@ohos.url` is used for hierarchical schemes.
 * That module cannot be relied on for non-hierarchical schemes, so the `file://`
 * form is parsed directly: everything after the third slash, with a
 * leading slash guaranteed. This matches the WHATWG `pathname` behaviour that
 * the ReadAny clients depend on.
 */
export function pathnameOf(urlValue: string): string {
  const trimmed: string = urlValue.trim();
  if (trimmed.startsWith('file://')) {
    const afterScheme: string = trimmed.substring('file://'.length);
    const slash: number = afterScheme.indexOf('/');
    if (slash < 0) {
      return '/';
    }
    const rest: string = afterScheme.substring(slash);
    return rest.length === 0 ? '/' : rest;
  }
  if (trimmed.startsWith('/')) {
    // Already a bare path.
    return trimmed;
  }
  try {
    const parsed: url.URL = url.URL.parseURL(trimmed);
    const path: string = parsed.pathname;
    return path.length === 0 ? '/' : path;
  } catch (err) {
    return trimmed;
  }
}

/** Trailing-slash form of a collection path. */
export function toCollectionPath(path: string): string {
  if (path === '/') {
    return '/';
  }
  return path.endsWith('/') ? path : `${path}/`;
}

/**
 * Trailing-slash form of a collection path, or the path unchanged when it is the
 * empty string.
 *
 * `toCollectionPath('')` would yield `/`, which turns "no path" into "the server
 * root" — a different resource, not a normalization of the same one. Callers that
 * may hold an empty path (`PROPFIND Depth: 0` on a resource whose name could not
 * be derived) must not be silently redirected to the root, so an empty input is
 * passed through.
 *
 * Idempotent by construction: a path that already ends in `/` is returned as-is,
 * so a caller that has already normalized cannot produce `//`. That is the whole
 * of the "must not double-slash" rule, and it is why this is a separate function
 * from `toCollectionPath` rather than a second append site.
 */
export function toCollectionRequestPath(path: string): string {
  if (path.length === 0) {
    return path;
  }
  return toCollectionPath(path);
}

/**
 * Normalize a decoded WebDAV path: collapse duplicate slashes, drop the
 * trailing slash, guarantee a leading slash. Ported from `normalizeWebDavPath`.
 */
export function normalizeWebDavPath(path: string): string {
  const decoded: string = safeDecode(path).replace(MULTI_SLASH, '/');
  const trimmed: string = decoded.replace(/\/+$/, '');
  if (trimmed.length === 0) {
    return '/';
  }
  return trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
}

/** `decodeURIComponent` that leaves malformed input alone. */
export function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch (err) {
    return value;
  }
}

/**
 * True when `hrefPath` is a *direct* child of `basePath`.
 *
 * PROPFIND `Depth: 1` also returns entries for deeper descendants on some
 * servers, and it always echoes the collection itself; both must be filtered out
 * or a listing would report grandchildren as direct children.
 */
export function isDirectChildPath(basePath: string, hrefPath: string): boolean {
  if (hrefPath === basePath) {
    return false;
  }
  const prefix: string = basePath === '/' ? '/' : `${basePath}/`;
  if (!hrefPath.startsWith(prefix)) {
    return false;
  }
  const relative: string = hrefPath.substring(prefix.length).replace(/\/+$/, '');
  return relative.length > 0 && !relative.includes('/');
}

/** Last path segment, i.e. the file name. */
export function filenameFromPath(path: string): string {
  const trimmed: string = path.replace(/\/+$/, '');
  const parts: string[] = trimmed.split('/');
  const last: string = parts.length > 0 ? parts[parts.length - 1] : '';
  return last.length > 0 ? last : '';
}

/** Join a parent logical path and a child name. */
export function joinLogicalPath(parentPath: string, name: string): string {
  const parent: string = parentPath.replace(/\/+$/, '') || '/';
  const encodedName: string = name.replace(LEADING_TRAILING_SLASHES, '');
  return parent === '/' ? `/${encodedName}` : `${parent}/${encodedName}`;
}

/** Reader for the remote root configured by the user. */
export interface RemoteRootConfig {
  /** Base URL as entered by the user. */
  baseUrl: string;
  /** Configured remote root, or empty to use the default. */
  remoteRoot: string;
}

/** Effective remote root, never empty. */
export function effectiveRemoteRoot(config: RemoteRootConfig): string {
  const sanitized: string = sanitizeWebDavRemoteRoot(config.remoteRoot);
  return sanitized.length > 0 ? sanitized : DEFAULT_REMOTE_ROOT;
}

/** True when the configured base URL already ends with the remote root. */
export function baseUrlAlreadyIncludesRemoteRoot(config: RemoteRootConfig): boolean {
  const remoteRoot: string = effectiveRemoteRoot(config);
  const basePath: string = pathnameOf(sanitizeWebDavUrl(config.baseUrl)).replace(LEADING_TRAILING_SLASHES, '');
  return basePath === remoteRoot || basePath.endsWith(`/${remoteRoot}`);
}

/**
 * Map a logical protocol path (`/readany/...`) onto the user's configured root.
 *
 * Two adjustments happen here: the literal `/readany` prefix becomes the
 * configured root, and when the base URL already contains that root the
 * duplicated segment is removed.
 */
export function resolveRemotePath(config: RemoteRootConfig, path: string): string {
  const remoteRoot: string = effectiveRemoteRoot(config);
  const resolved: string = replaceLogicalRoot(path, remoteRoot);

  if (
    baseUrlAlreadyIncludesRemoteRoot(config) &&
    (resolved === `/${remoteRoot}` || resolved.startsWith(`/${remoteRoot}/`))
  ) {
    const deduped: string = resolved.substring(remoteRoot.length + 1);
    if (deduped.length === 0) {
      return '/';
    }
    return deduped.startsWith('/') ? deduped : `/${deduped}`;
  }
  return resolved;
}

/** Replace a leading `/readany` segment with the configured root. */
function replaceLogicalRoot(path: string, remoteRoot: string): string {
  if (remoteRoot === DEFAULT_REMOTE_ROOT) {
    return path;
  }
  const rootLen: number = REMOTE_ROOT.length;
  if (path === REMOTE_ROOT) {
    return `/${remoteRoot}`;
  }
  if (path.startsWith(`${REMOTE_ROOT}/`)) {
    return `/${remoteRoot}${path.substring(rootLen)}`;
  }
  return path;
}

/**
 * Percent-encode each path segment while preserving `/`, matching
 * `WebDavClient.buildUrl`. Book and cover folder names routinely contain CJK
 * characters and spaces, so this is exercised on every transfer.
 */
export function encodePathSegments(path: string): string {
  const normalized: string = path.startsWith('/') ? path : `/${path}`;
  const segments: string[] = normalized.split('/');
  const encoded: string[] = [];
  for (let i = 0; i < segments.length; i++) {
    encoded.push(encodeURIComponent(segments[i]));
  }
  return encoded.join('/');
}

/** Build an absolute request URL from the base URL and a remote path. */
export function buildRequestUrl(baseUrl: string, path: string): string {
  return `${sanitizeWebDavUrl(baseUrl)}${encodePathSegments(path)}`;
}
