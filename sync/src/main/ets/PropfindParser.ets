/**
 * PROPFIND multistatus parser.
 *
 * Ported from ReadAny `packages/core/src/sync/webdav-client.ts`
 * (`parsePropfindResponse` / `parsePropfindBlocks` / `extractTagContent`).
 *
 * The ReadAny clients deliberately hand-roll this with regexes instead of an XML
 * DOM, because servers vary wildly in namespace prefixes (`D:`, `d:`, `ns0:`, or
 * none at all) and stripping namespaces first is cheaper and more predictable
 * than configuring a parser. The same approach is kept here so that a server
 * that works for the desktop client works for this one.
 */

import type { RemoteResource } from './WebDavTypes';
import {
  filenameFromPath,
  isDirectChildPath,
  normalizeWebDavPath,
  pathnameOf,
  safeDecode,
} from './RemotePaths';

/** `<response>`, with or without a namespace prefix. */
const RESPONSE_BLOCK_RE: RegExp =
  /<(?:[\w-]+:)?response\b[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?response>/gi;
/** A `<collection/>` element anywhere in a response, wrapped or self-closed. */
const COLLECTION_RE: RegExp = /<(?:(?:\w+):)?collection\b[^>]*\/?>/i;

/**
 * Build a case-insensitive matcher for a literal, so that XML tag names match
 * regardless of case without relying on the `i` flag's Unicode folding.
 */
function literalPattern(literal: string): string {
  let out: string = '';
  for (let i = 0; i < literal.length; i++) {
    const ch: string = literal.charAt(i);
    if ('\\^$.|?*+()[]{}'.includes(ch)) {
      out += `\\${ch}`;
    } else {
      out += `[${ch}${ch.toUpperCase()}]`;
    }
  }
  return out;
}

/**
 * Text content of the first `<localName>` element, trimmed.
 *
 * Returns `null` only when the tag is absent. An empty element yields `""`, not
 * `null` — the reference implementation makes that distinction and a caller that
 * cares (for example `getcontentlength`) relies on it to tell "not reported"
 * apart from "reported as empty".
 */
export function extractTagContent(xml: string, localName: string): string | null {
  const name: string = literalPattern(localName);
  const regex: RegExp = new RegExp(`<(?:[\\w-]+:)?${name}\\b[^>]*>([^<]*)<\\/(?:[\\w-]+:)?${name}>`);
  const match: RegExpExecArray | null = regex.exec(xml);
  return match !== null ? match[1].trim() : null;
}

/** Split a multistatus body into per-`<response>` blocks. */
export function splitResponseBlocks(xml: string): string[] {
  const blocks: string[] = [];
  const regex: RegExp = new RegExp(RESPONSE_BLOCK_RE.source, RESPONSE_BLOCK_RE.flags);
  let match: RegExpExecArray | null = regex.exec(xml);
  while (match !== null) {
    blocks.push(match[1]);
    match = regex.exec(xml);
  }
  return blocks;
}

/**
 * Convert one `<response>` block into a resource, or return `undefined` when it
 * is not a direct child of the requested collection.
 */
export function parsePropfindBlock(
  block: string,
  basePath: string,
  requestUrl: string,
): RemoteResource | undefined {
  const href: string = extractTagContent(block, 'href') ?? '';
  const hrefPath: string = normalizeWebDavPath(getPathnameFromHref(href, requestUrl));
  if (!isDirectChildPath(basePath, hrefPath)) {
    return undefined;
  }

  const contentLengthText: string | null = extractTagContent(block, 'getcontentlength');
  const contentLength: number =
    contentLengthText !== null ? Number.parseInt(contentLengthText, 10) : 0;
  const lastModified: string = extractTagContent(block, 'getlastmodified') ?? '';
  const rawEtag: string | null = extractTagContent(block, 'getetag');

  return {
    href: hrefPath,
    name: filenameFromPath(hrefPath),
    isCollection: COLLECTION_RE.test(block),
    contentLength: Number.isNaN(contentLength) ? 0 : contentLength,
    lastModified: lastModified,
    etag: rawEtag !== null ? rawEtag.replace(/"/g, '') : '',
  };
}

/**
 * Resolve an `href` to a path.
 *
 * Servers return either an absolute URL, an absolute path, or (rarely) a
 * path-relative reference; all three occur in the wild and all three are used
 * here. Parsing is manual rather than delegating to `@ohos.url` because `file:`
 * and scheme-less values are common in this position.
 */
function getPathnameFromHref(href: string, requestUrl: string): string {
  const value: string = href.trim();
  if (value.length === 0) {
    return '';
  }
  if (value.startsWith('/')) {
    return value;
  }
  if (value.includes('://')) {
    return pathnameOf(value);
  }
  // Relative reference: resolve against the request URL's directory.
  const base: string = pathnameOf(requestUrl);
  const cut: number = base.lastIndexOf('/');
  const dir: string = cut >= 0 ? base.substring(0, cut + 1) : '/';
  return `${dir}${value}`;
}

/**
 * Everything a caller needs to tell "this collection is genuinely empty" apart
 * from "this body was not a listing this parser could read".
 *
 * Having to make that distinction is the point. Before this existed, a body the
 * parser did not understand and a collection with nothing in it both came back as
 * an empty array; the caller could only treat all 18 books as absent, and the
 * resulting sync reported no transfers with no reason anywhere. The counts below
 * are what makes the two cases distinguishable without guessing at the body.
 *
 * This is not a "be lenient" hook. The parser accepts exactly the `href` forms a
 * WebDAV server is allowed to send — an absolute path, an absolute URL on any
 * host, or a reference relative to the request URL — and each of those is exercised
 * against the reference implementation in `tools/verify-sync-port.mjs`. A body whose
 * blocks carry no `href` at all, or whose `href` values name a different collection
 * than the one requested, is *reported* through these counts rather than
 * reinterpreted: guessing at such a body is what would let a listing silently
 * describe the wrong directory.
 */
export interface PropfindParseReport {
  /** `<response>` blocks found in the body. */
  blocks: number;
  /** `<href>` elements among them (usually equal to `blocks`). */
  hrefs: number;
  /** Blocks accepted as direct children of the base path. */
  children: number;
  /** True when the request URL's pathname did not match and the logical path was used. */
  usedFallback: boolean;
  /** Normalized base path derived from the request URL. */
  strictBasePath: string;
  /** Normalized base path derived from the logical path the caller passed. */
  fallbackBasePath: string;
}

/** A parsed listing together with the evidence for how it came out. */
export interface ParsedListing {
  resources: RemoteResource[];
  report: PropfindParseReport;
}

/** Running totals for one pass over the response blocks. */
interface BlockStats {
  blocks: number;
  hrefs: number;
  children: number;
}

/**
 * Parse a listing, retaining the counts.
 *
 * `parsePropfindResponse` is this function's projection; it is kept as the public
 * shape because every existing caller and the differential port test use it.
 */
export function parsePropfindDetailed(
  xml: string,
  logicalPath: string,
  requestUrl: string,
): ParsedListing {
  const blocks: string[] = splitResponseBlocks(xml);
  const strictBasePath: string = normalizeWebDavPath(pathnameOf(requestUrl));
  const fallbackBasePath: string = normalizeWebDavPath(logicalPath);

  const stats: BlockStats = { blocks: blocks.length, hrefs: 0, children: 0 };
  let resources: RemoteResource[] = parseBlocks(blocks, strictBasePath, requestUrl, stats);

  // Some servers echo a different casing or an extra mount prefix in `href` than in
  // the request. The fallback is tried only when the strict base path matched
  // nothing, so a server that answers the direct way cannot be reinterpreted.
  let usedFallback: boolean = false;
  if (resources.length === 0 && fallbackBasePath !== strictBasePath) {
    stats.children = 0;
    resources = parseBlocks(blocks, fallbackBasePath, requestUrl, stats);
    usedFallback = resources.length > 0;
  }

  const report: PropfindParseReport = {
    blocks: stats.blocks,
    hrefs: stats.hrefs,
    children: stats.children,
    usedFallback: usedFallback,
    strictBasePath: strictBasePath,
    fallbackBasePath: fallbackBasePath,
  };
  return { resources: resources, report: report };
}

/**
 * Parse a complete multistatus body into direct children of the requested
 * collection.
 *
 * Two candidate base paths are tried: the request URL's own pathname, and the
 * logical path the caller asked for. Some servers echo a different casing or an
 * extra mount prefix in `href` than in the request, and falling back keeps the
 * listing working instead of silently returning zero entries.
 */
export function parsePropfindResponse(
  xml: string,
  logicalPath: string,
  requestUrl: string,
): RemoteResource[] {
  return parsePropfindDetailed(xml, logicalPath, requestUrl).resources;
}

function parseBlocks(
  blocks: string[],
  basePath: string,
  requestUrl: string,
  stats: BlockStats,
): RemoteResource[] {
  const resources: RemoteResource[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const block: string = blocks[i];
    if (extractTagContent(block, 'href') !== null) {
      stats.hrefs++;
    }
    const resource: RemoteResource | undefined =
      parsePropfindBlock(block, basePath, requestUrl);
    if (resource !== undefined) {
      resources.push(resource);
    }
  }
  stats.children = resources.length;
  return resources;
}

/** Re-exported for callers that need to decode an href path themselves. */
export { safeDecode };
