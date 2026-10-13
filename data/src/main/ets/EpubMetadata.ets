/**
 * EPUB metadata parsing.
 *
 * Reads only what the shelf and the library row need: title, author, language,
 * publisher, description, the spine length, and the cover image's bytes.
 *
 * The EPUB container is a ZIP, and this platform has no entry-level ZIP reader —
 * `@ohos.zlib` only decompresses whole archives. So the caller extracts to a
 * temporary directory and hands this module an `EpubSource` that reads files by
 * their in-archive path. Keeping that as an interface rather than a directory
 * path is what makes this logic testable without a device: the cross-check script
 * supplies an in-memory source built from a fixture.
 *
 * XML is parsed with regexes rather than a DOM, matching how the sync layer
 * already reads server responses. EPUB metadata is a small, predictable subset of
 * XML, and a full parser would add a dependency for no benefit.
 */

import { util } from '@kit.ArkTS';

/** Reads one file out of an extracted EPUB, by its in-archive path. */
export interface EpubSource {
  /**
   * Read a file, or return `undefined` when it does not exist.
   *
   * Paths are relative to the archive root and may contain `/`. Callers pass
   * paths exactly as the OPF or container refers to them (already resolved
   * against the OPF's own directory).
   */
  read(path: string): Promise<Uint8Array | undefined>;

  /** Every file path in the archive, for the cover-manifest-name fallback. */
  list(): Promise<string[]>;
}

/** What an import records about a book. */
export interface EpubMetadata {
  title: string;
  author: string;
  language: string;
  publisher: string;
  description: string;
  /** Number of spine items, used as the chapter count. */
  chapterCount: number;
  /** `EPUB` package version, informational. */
  version: string;
  /** Cover bytes, or `undefined` when the book has no usable cover. */
  cover: Uint8Array | undefined;
  /** Extension of the cover image, without a dot. */
  coverExt: string;
}

export function emptyEpubMetadata(): EpubMetadata {
  return {
    title: '',
    author: '',
    language: '',
    publisher: '',
    description: '',
    chapterCount: 0,
    version: '',
    cover: undefined,
    coverExt: '',
  };
}

/** `META-INF/container.xml`, where the package document's path is declared. */
const CONTAINER_PATH: string = 'META-INF/container.xml';

/** Fallback locations for the package document when `container.xml` is missing. */
const OPF_FALLBACKS: string[] = ['content.opf', 'OEBPS/content.opf', 'OPS/content.opf', 'package.opf'];

/**
 * Parse metadata from an extracted EPUB.
 *
 * Never throws: a malformed EPUB yields whatever could be read. Import is a user
 * action on a file the app did not produce, and refusing to add a book because one
 * optional element is malformed would be worse than adding it with a blank field.
 */
export async function parseEpub(source: EpubSource): Promise<EpubMetadata> {
  const metadata: EpubMetadata = emptyEpubMetadata();

  const opfPath: string = await findOpfPath(source);
  if (opfPath.length === 0) {
    return metadata;
  }

  const opfBytes: Uint8Array | undefined = await source.read(opfPath);
  if (opfBytes === undefined) {
    return metadata;
  }
  const opf: string = decodeUtf8(opfBytes);

  metadata.version = attributeIn(opf, 'package', 'version');

  // Metadata lives under <metadata>; restricting the search to that element avoids
  // matching a same-named tag inside the manifest or a guide reference.
  const metadataBlock: string = blockOf(opf, 'metadata');
  const scope: string = metadataBlock.length > 0 ? metadataBlock : opf;

  // EPUB 3 uses `dc:` prefixes; EPUB 2 files often use `dc:` too but some omit it.
  metadata.title = firstTagValue(scope, ['dc:title', 'title']);
  metadata.author = firstTagValue(scope, ['dc:creator', 'creator']);
  metadata.language = firstTagValue(scope, ['dc:language', 'language']);
  metadata.publisher = firstTagValue(scope, ['dc:publisher', 'publisher']);
  metadata.description = firstTagValue(scope, ['dc:description', 'description']);

  // The spine's itemref count is the chapter count. Counting the whole document
  // instead would include the manifest's own items, which is a different number.
  const spineBlock: string = blockOf(opf, 'spine');
  metadata.chapterCount = countTags(spineBlock, 'itemref');

  // ---- cover -------------------------------------------------------------
  const opfDir: string = directoryOf(opfPath);
  const coverHref: string = findCoverHref(opf, metadataBlock, scope);
  if (coverHref.length > 0) {
    const resolved: string = resolveRelative(opfDir, coverHref);
    const bytes: Uint8Array | undefined = await source.read(resolved);
    if (bytes !== undefined && bytes.length > 0) {
      metadata.cover = bytes;
      metadata.coverExt = extensionOf(resolved);
      return metadata;
    }
  }

  // Fallback: an image in the archive whose name suggests it is the cover. Many
  // hand-made EPUBs declare no cover metadata at all but ship `cover.jpg`.
  const named: string | undefined = await findCoverByName(source);
  if (named !== undefined) {
    const bytes: Uint8Array | undefined = await source.read(named);
    if (bytes !== undefined && bytes.length > 0) {
      metadata.cover = bytes;
      metadata.coverExt = extensionOf(named);
    }
  }
  return metadata;
}

/** Locate the package document. */
async function findOpfPath(source: EpubSource): Promise<string> {
  const containerBytes: Uint8Array | undefined = await source.read(CONTAINER_PATH);
  if (containerBytes !== undefined) {
    const container: string = decodeUtf8(containerBytes);
    // `<rootfile full-path="OEBPS/content.opf" .../>`
    const fullPath: string = attributeIn(container, 'rootfile', 'full-path');
    if (fullPath.length > 0) {
      return fullPath;
    }
  }
  for (const candidate of OPF_FALLBACKS) {
    if (await source.read(candidate) !== undefined) {
      return candidate;
    }
  }
  // Last resort: any `.opf` in the archive, so an unusual layout still imports.
  const files: string[] = await source.list();
  for (const file of files) {
    if (file.toLowerCase().endsWith('.opf')) {
      return file;
    }
  }
  return '';
}

/**
 * The cover image href, from the three places EPUBs declare it.
 *
 * Order matters. The EPUB 3 `properties="cover-image"` attribute is authoritative;
 * the EPUB 2 `<meta name="cover" content="..."/>` indirection names a manifest id
 * that then has to be resolved; `guide` references are the oldest form.
 */
function findCoverHref(opf: string, metadataBlock: string, scope: string): string {
  const manifestBlock: string = blockOf(opf, 'manifest');

  // EPUB 3: <item id="x" href="cover.jpg" properties="cover-image"/>
  const epub3: string = itemHrefWithProperty(manifestBlock, 'cover-image');
  if (epub3.length > 0) {
    return epub3;
  }

  // EPUB 2: <meta name="cover" content="cover-id"/> then the item with that id.
  const coverId: string = metaContent(metadataBlock.length > 0 ? metadataBlock : scope, 'cover');
  if (coverId.length > 0) {
    const href: string = itemHrefById(manifestBlock, coverId);
    if (href.length > 0) {
      return href;
    }
  }

  // Guide reference: <reference type="cover" href="cover.html"/>
  const guideBlock: string = blockOf(opf, 'guide');
  if (guideBlock.length > 0) {
    const guideHref: string = attributeIn(guideBlock, 'reference', 'href');
    if (guideHref.length > 0) {
      return guideHref;
    }
  }

  // Some EPUBs name the manifest item "cover" without any of the above.
  const byId: string = itemHrefById(manifestBlock, 'cover');
  if (byId.length > 0) {
    return byId;
  }
  return '';
}

/** An image in the archive whose name looks like a cover. */
async function findCoverByName(source: EpubSource): Promise<string | undefined> {
  const files: string[] = await source.list();
  const candidates: string[] = [];
  for (const file of files) {
    const lower: string = file.toLowerCase();
    if (!isImageName(lower)) {
      continue;
    }
    const name: string = lower.substring(lower.lastIndexOf('/') + 1);
    if (name.startsWith('cover') || name.includes('cover.')) {
      candidates.push(file);
    }
  }
  if (candidates.length === 0) {
    return undefined;
  }
  // Prefer the shortest path: `OEBPS/cover.jpg` over `OEBPS/images/back-cover.jpg`.
  candidates.sort((a: string, b: string): number => a.length - b.length);
  return candidates[0];
}

function isImageName(lower: string): boolean {
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png')
    || lower.endsWith('.webp') || lower.endsWith('.gif');
}

// ---------------------------------------------------------------------------
// Small XML helpers
//
// Deliberately regex-based, and deliberately case-insensitive on tag names while
// exact on attribute names: XML is case-sensitive for attributes but real EPUBs
// disagree about tag case often enough that tolerating it avoids blank metadata.
// ---------------------------------------------------------------------------

/** Text content of the first matching tag among `names`, trimmed. */
export function firstTagValue(xml: string, names: string[]): string {
  for (const name of names) {
    const value: string = tagValue(xml, name);
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Text content of the first `<name>` element, trimmed, or an empty string. */
export function tagValue(xml: string, name: string): string {
  const pattern: string = literalPattern(name);
  const regex: RegExp = new RegExp(`<(?:[\\w-]+:)?${pattern}\\b[^>]*>([\\s\\S]*?)<\\/(?:[\\w-]+:)?${pattern}>`);
  const match: RegExpExecArray | null = regex.exec(xml);
  if (match === null) {
    return '';
  }
  return decodeEntities(stripTags(match[1])).trim();
}

/** Attributes of every `<name .../>` element, in document order. */
export function tagAttributes(xml: string, name: string): Map<string, string>[] {
  const out: Map<string, string>[] = [];
  const pattern: string = literalPattern(name);
  const regex: RegExp = new RegExp(`<(?:[\\w-]+:)?${pattern}\\b([^>]*?)\\/?>`, 'g');
  let match: RegExpExecArray | null = regex.exec(xml);
  while (match !== null) {
    out.push(parseAttributes(match[1]));
    match = regex.exec(xml);
  }
  return out;
}

/** Attribute value of the first `<name>` element, or an empty string. */
export function attributeIn(xml: string, name: string, attribute: string): string {
  const all: Map<string, string>[] = tagAttributes(xml, name);
  for (const attrs of all) {
    const value: string | undefined = attrs.get(attribute);
    if (value !== undefined && value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Inner content of the first `<name>` element, or an empty string. */
export function blockOf(xml: string, name: string): string {
  const pattern: string = literalPattern(name);
  const regex: RegExp = new RegExp(`<(?:[\\w-]+:)?${pattern}\\b[^>]*>([\\s\\S]*?)<\\/(?:[\\w-]+:)?${pattern}>`);
  const match: RegExpExecArray | null = regex.exec(xml);
  return match !== null ? match[1] : '';
}

/** How many `<name>` elements appear in `xml`. */
export function countTags(xml: string, name: string): number {
  if (xml.length === 0) {
    return 0;
  }
  const pattern: string = literalPattern(name);
  const regex: RegExp = new RegExp(`<(?:[\\w-]+:)?${pattern}\\b`, 'g');
  let count: number = 0;
  let match: RegExpExecArray | null = regex.exec(xml);
  while (match !== null) {
    count++;
    match = regex.exec(xml);
  }
  return count;
}

/** href of the first `<item>` carrying the given `properties` token. */
export function itemHrefWithProperty(manifest: string, property: string): string {
  const items: Map<string, string>[] = tagAttributes(manifest, 'item');
  for (const attrs of items) {
    const properties: string = attrs.get('properties') ?? '';
    for (const token of properties.split(/\s+/)) {
      if (token === property) {
        return attrs.get('href') ?? '';
      }
    }
  }
  return '';
}

/** href of the `<item>` with the given id. */
export function itemHrefById(manifest: string, id: string): string {
  const items: Map<string, string>[] = tagAttributes(manifest, 'item');
  for (const attrs of items) {
    if ((attrs.get('id') ?? '') === id) {
      return attrs.get('href') ?? '';
    }
  }
  return '';
}

/** `content` of the `<meta name="...">` element. */
export function metaContent(xml: string, name: string): string {
  const metas: Map<string, string>[] = tagAttributes(xml, 'meta');
  for (const attrs of metas) {
    if ((attrs.get('name') ?? '') === name) {
      return attrs.get('content') ?? '';
    }
  }
  return '';
}

/** Parse an attribute list into a map, lowercasing attribute names. */
export function parseAttributes(text: string): Map<string, string> {
  const out: Map<string, string> = new Map<string, string>();
  const regex: RegExp = /([\w:.-]+)\s*=\s*("([^"]*)"|'([^']*)')/g;
  let match: RegExpExecArray | null = regex.exec(text);
  while (match !== null) {
    const name: string = match[1].toLowerCase();
    const value: string = match[3] !== undefined ? match[3] : (match[4] ?? '');
    out.set(name, decodeEntities(value));
    match = regex.exec(text);
  }
  return out;
}

/** Directory part of an archive path, without a trailing slash. */
export function directoryOf(path: string): string {
  const cut: number = path.lastIndexOf('/');
  return cut < 0 ? '' : path.substring(0, cut);
}

/** Lower-case extension without the dot. */
export function extensionOf(path: string): string {
  const name: string = path.substring(path.lastIndexOf('/') + 1);
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return name.substring(dot + 1).toLowerCase();
}

/**
 * Resolve a possibly-relative href against a base directory, normalizing `..`.
 *
 * EPUB manifest hrefs are relative to the package document, and frequently look
 * like `../Images/cover.jpg`, so collapsing `..` is required rather than cosmetic.
 */
export function resolveRelative(baseDir: string, href: string): string {
  let path: string = href;
  // Strip a fragment or query; an href like `cover.jpg#x` names the same file.
  const hash: number = path.indexOf('#');
  if (hash >= 0) {
    path = path.substring(0, hash);
  }
  const query: number = path.indexOf('?');
  if (query >= 0) {
    path = path.substring(0, query);
  }
  path = safeDecode(path);
  if (path.startsWith('/')) {
    return collapse(path);
  }
  const combined: string = baseDir.length > 0 ? `${baseDir}/${path}` : path;
  return collapse(combined);
}

/** Collapse `.` and `..` segments. */
function collapse(path: string): string {
  const parts: string[] = path.split('/');
  const out: string[] = [];
  for (const part of parts) {
    if (part.length === 0 || part === '.') {
      continue;
    }
    if (part === '..') {
      if (out.length > 0) {
        out.pop();
      }
      continue;
    }
    out.push(part);
  }
  return out.join('/');
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch (err) {
    return value;
  }
}

/** Build a case-insensitive matcher for a literal tag name. */
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

/** Remove nested tags, keeping their text. */
function stripTags(text: string): string {
  return text.replace(/<[^>]*>/g, '');
}

/** Decode the XML entities that actually appear in EPUB metadata. */
export function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (match: string, code: string): string => {
      const value: number = Number.parseInt(code, 10);
      return Number.isNaN(value) ? match : String.fromCharCode(value);
    })
    .replace(/&#x([0-9a-fA-F]+);/g, (match: string, code: string): string => {
      const value: number = Number.parseInt(code, 16);
      return Number.isNaN(value) ? match : String.fromCharCode(value);
    })
    // Ampersand last, so `&amp;lt;` becomes `&lt;` rather than `<`.
    .replace(/&amp;/g, '&');
}

/** Decode UTF-8 bytes, tolerating malformed input. */
export function decodeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: false }).decodeToString(bytes);
}
