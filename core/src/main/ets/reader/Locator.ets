/**
 * Annotation position encoding.
 *
 * ReadAny stores an EPUB CFI in `bookmarks.cfi` / `highlights.cfi` /
 * `notes.cfi`. Reader Kit, however, positions a book by `(spineIndex, domPos)`,
 * and this client's reader produces that, not a CFI.
 *
 * So an annotation created here needs a string that:
 *  1. sorts correctly on this device, which `compareCfiPosition` can already do —
 *     it compares decimal runs in order, and `spine:3:...` yields `[3]`;
 *  2. is clearly *not* a CFI, so a peer that tries to resolve it fails visibly
 *     rather than jumping to a wrong place;
 *  3. round-trips the DOM position, which is the only thing that restores an exact
 *     spot inside a spine item.
 *
 * Format: `spine:{index}:{domPos}`
 *
 * The honest limitation: such an annotation is **not navigable on a ReadAny
 * client**, and a CFI written by ReadAny is not navigable here. Position
 * interoperability needs a CFI mapping that does not exist yet. Everything else
 * about the annotation — text, colour, note body, chapter title, timestamps —
 * syncs normally.
 */

/** Prefix identifying a Reader Kit locator. */
export const SPINE_LOCATOR_PREFIX: string = 'spine:';

/** A position this client can act on. */
export interface SpineLocator {
  spineIndex: number;
  domPos: string;
}

/**
 * Encode a Reader Kit position.
 *
 * The DOM position is appended verbatim, including any `:` it may contain
 * (`/html/body/div[2]/p[1]:12` is a realistic value), which is why parsing splits
 * on the first two colons only.
 */
export function encodeSpineLocator(spineIndex: number, domPos: string): string {
  return `${SPINE_LOCATOR_PREFIX}${spineIndex}:${domPos}`;
}

/**
 * Decode a locator, or return `undefined` when it is not one of ours.
 *
 * Returning `undefined` rather than a best guess is deliberate: callers use this
 * to decide whether they can navigate, and a fabricated position would send the
 * reader to the wrong page.
 */
export function decodeSpineLocator(value: string): SpineLocator | undefined {
  if (!value.startsWith(SPINE_LOCATOR_PREFIX)) {
    return undefined;
  }
  const rest: string = value.substring(SPINE_LOCATOR_PREFIX.length);
  const separator: number = rest.indexOf(':');
  if (separator < 0) {
    // `spine:3` with no DOM position is still usable: it lands at the start of
    // that spine item, which is what a bookmark saved before the first page
    // report would record.
    const onlyIndex: number = Number.parseInt(rest, 10);
    if (Number.isNaN(onlyIndex)) {
      return undefined;
    }
    return { spineIndex: onlyIndex, domPos: '' };
  }
  const indexText: string = rest.substring(0, separator);
  const spineIndex: number = Number.parseInt(indexText, 10);
  if (Number.isNaN(spineIndex)) {
    return undefined;
  }
  return { spineIndex: spineIndex, domPos: rest.substring(separator + 1) };
}

/** True when a stored position is a Reader Kit locator rather than a CFI. */
export function isSpineLocator(value: string): boolean {
  return value.startsWith(SPINE_LOCATOR_PREFIX);
}

/**
 * True when the value looks like an EPUB CFI a peer wrote.
 *
 * Used by the UI to explain why a synced bookmark cannot be opened here, instead
 * of offering a tap that does nothing.
 */
export function isEpubCfi(value: string): boolean {
  return value.startsWith('epubcfi(');
}

/** True when the value is a PDF page marker. */
export function isPageMarker(value: string): boolean {
  return /^page:\d+$/i.test(value.trim());
}

/** What kind of position a stored value is. */
export enum LocatorKind {
  /** A locator this client wrote and can navigate. */
  SPINE = 'spine',
  /** An EPUB CFI written by a ReadAny client; not navigable here. */
  EPUB_CFI = 'epub-cfi',
  /** A `page:{N}` marker. */
  PAGE = 'page',
  /** Empty or unrecognised. */
  UNKNOWN = 'unknown',
}

export function classifyLocator(value: string): LocatorKind {
  if (isSpineLocator(value)) {
    return LocatorKind.SPINE;
  }
  if (isEpubCfi(value)) {
    return LocatorKind.EPUB_CFI;
  }
  if (isPageMarker(value)) {
    return LocatorKind.PAGE;
  }
  return LocatorKind.UNKNOWN;
}

/**
 * A short human label for a position, for list rows.
 *
 * A CFI is shown truncated rather than hidden: the user needs to know the
 * annotation exists and where it came from, even when this device cannot open it.
 */
export function describeLocator(value: string, chapterTitle: string): string {
  if (chapterTitle.length > 0) {
    return chapterTitle;
  }
  switch (classifyLocator(value)) {
    case LocatorKind.SPINE: {
      const decoded: SpineLocator | undefined = decodeSpineLocator(value);
      return decoded !== undefined ? `第 ${decoded.spineIndex + 1} 节` : '未知位置';
    }
    case LocatorKind.EPUB_CFI:
      return `CFI ${value.length > 24 ? `${value.substring(0, 24)}…` : value}`;
    case LocatorKind.PAGE:
      return value;
    default:
      return '未知位置';
  }
}
