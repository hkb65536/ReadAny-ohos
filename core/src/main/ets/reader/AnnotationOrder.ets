/**
 * Book-position ordering for bookmarks, highlights and notes.
 *
 * Ported from ReadAny `packages/core/src/reader/annotation-order.ts` and kept
 * behaviourally identical, because the desktop and mobile clients sort with the
 * same rules and a mismatch would make "next bookmark" jump around after sync.
 *
 * Positions come in two flavours:
 *   - EPUB: a standard EPUB CFI string, e.g. `epubcfi(/6/14!/4/2/2:0)`
 *   - PDF:  a pseudo-CFI `page:{N}`, 1-based
 */

/** Anything that can be placed inside a book. */
export interface PositionedAnnotation {
  cfi: string;
  createdAt: number;
}

/**
 * Numeric segments of a CFI. Returns `null` when the value is not a
 * `page:{N}` pseudo-CFI so the caller can fall back to CFI parsing.
 */
export function parsePageCfi(cfi: string): number[] | null {
  const match: RegExpMatchArray | null = cfi.match(/^page:(\d+)$/i);
  if (match === null) {
    return null;
  }
  const parsed: number = Number.parseInt(match[1], 10);
  if (Number.isNaN(parsed)) {
    return null;
  }
  return [parsed];
}

/**
 * Numeric segments of an EPUB CFI, in document order.
 *
 * Note: this is a deliberately shallow reading of the CFI grammar — it collects
 * every decimal run and ignores the `!` (indirection) and `:` (character
 * offset) separators. It matches the existing clients exactly; making it more
 * correct here would make it disagree with them.
 */
export function parseEpubCfi(cfi: string): number[] {
  const trimmed: string = cfi.trim();
  const inner: string =
    trimmed.startsWith('epubcfi(') && trimmed.endsWith(')')
      ? trimmed.substring(8, trimmed.length - 1)
      : trimmed;

  const parts: number[] = [];
  const matcher: RegExp = /\d+/g;
  let found: RegExpExecArray | null = matcher.exec(inner);
  while (found !== null) {
    const value: number = Number.parseInt(found[0], 10);
    if (!Number.isNaN(value)) {
      parts.push(value);
    }
    found = matcher.exec(inner);
  }
  return parts;
}

/** Sort key for a position. Missing positions sort last. */
function getCfiSortKey(cfi: string): number[] {
  const trimmed: string = cfi.trim();
  if (trimmed.length === 0) {
    return [Number.POSITIVE_INFINITY];
  }
  const page: number[] | null = parsePageCfi(trimmed);
  const parsed: number[] = page !== null ? page : parseEpubCfi(trimmed);
  return parsed.length > 0 ? parsed : [Number.POSITIVE_INFINITY];
}

/** Compare two positions inside a book. Negative means `left` comes first. */
export function compareCfiPosition(leftCfi: string, rightCfi: string): number {
  const left: number[] = getCfiSortKey(leftCfi);
  const right: number[] = getCfiSortKey(rightCfi);
  const length: number = Math.max(left.length, right.length);

  for (let i = 0; i < length; i++) {
    const leftPart: number = i < left.length ? left[i] : -1;
    const rightPart: number = i < right.length ? right[i] : -1;
    if (leftPart !== rightPart) {
      return leftPart - rightPart;
    }
  }
  return leftCfi.localeCompare(rightCfi);
}

/**
 * Document order, breaking ties by creation time so a stable list survives
 * re-syncs that deliver rows in a different order.
 */
export function compareAnnotationPosition(
  left: PositionedAnnotation,
  right: PositionedAnnotation,
): number {
  const byPosition: number = compareCfiPosition(left.cfi, right.cfi);
  return byPosition !== 0 ? byPosition : left.createdAt - right.createdAt;
}

/** Non-mutating sort by position. */
export function sortAnnotationsByPosition<T extends PositionedAnnotation>(items: T[]): T[] {
  const copy: T[] = items.slice();
  copy.sort((a: T, b: T): number => compareAnnotationPosition(a, b));
  return copy;
}

/** Highlight colours, matching ReadAny's palette. */
export type HighlightColor =
  | 'red'
  | 'yellow'
  | 'green'
  | 'blue'
  | 'pink'
  | 'purple'
  | 'violet';

/** Hex colour per persisted colour name. */
export interface HighlightColorHex {
  red: string;
  yellow: string;
  green: string;
  blue: string;
  pink: string;
  purple: string;
  violet: string;
}

/**
 * Hex values per persisted colour name.
 *
 * Declared in `core` rather than in `data` so the renderer and any export path
 * share one definition; `data` re-exports it. A dedicated interface is used
 * instead of `Record<string, string>` because ArkTS does not accept the built-in
 * `Record` utility type as the declared type of an object literal
 * (`arkts-no-untyped-obj-literals`).
 */
export const HIGHLIGHT_COLOR_HEX: HighlightColorHex = {
  red: '#F5222D',
  yellow: '#FADB14',
  green: '#52C41A',
  blue: '#1890FF',
  pink: '#EB2F96',
  purple: '#722ED1',
  violet: '#B37FEB',
};

/** Colours offered in the selection popover, in display order. */
export const HIGHLIGHT_COLORS: string[] = ['yellow', 'green', 'blue', 'pink', 'purple'];

/**
 * Hex for a colour name, or a neutral grey for anything unrecognised.
 *
 * A function rather than `HIGHLIGHT_COLOR_HEX[name]` because ArkTS forbids indexed
 * access on a typed object (`arkts-no-props-by-index`). An explicit switch also
 * means a colour added to the union but not here is a visible grey dot rather than
 * an exception during render.
 */
export function highlightColorHex(color: string): string {
  switch (color) {
    case 'red':
      return HIGHLIGHT_COLOR_HEX.red;
    case 'yellow':
      return HIGHLIGHT_COLOR_HEX.yellow;
    case 'green':
      return HIGHLIGHT_COLOR_HEX.green;
    case 'blue':
      return HIGHLIGHT_COLOR_HEX.blue;
    case 'pink':
      return HIGHLIGHT_COLOR_HEX.pink;
    case 'purple':
      return HIGHLIGHT_COLOR_HEX.purple;
    case 'violet':
      return HIGHLIGHT_COLOR_HEX.violet;
    default:
      return '#999999';
  }
}

/**
 * Shared SQL `ORDER BY` fragment for on-disk annotation queries.
 *
 * The reference implementation orders by `created_at DESC` in SQL and then
 * re-sorts in JS by position, which makes the SQL ordering dead weight. This port
 * keeps the JS sort as the single source of order, so the clause here is a stable
 * tie-break for identical timestamps only.
 */
export const ANNOTATION_STABLE_ORDER: string = 'ORDER BY created_at ASC, id ASC';
