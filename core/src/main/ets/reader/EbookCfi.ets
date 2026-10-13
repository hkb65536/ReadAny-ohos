/**
 * EPUB CFI ↔ Reader Kit spine index.
 *
 * A ReadAny client records a reading position as an EPUB CFI; this client records
 * one as a Reader Kit `(spineIndex, domPos)` pair. The two coordinate systems do
 * **not** map onto each other in general, and this file deliberately maps only the
 * part that is honest:
 *
 *  - **What maps.** The spine step of a CFI, `epubcfi(/6/N!/...)`, names one spine
 *    item. `N` is an even child index, so the 0-based spine ordinal is `N/2 - 1`
 *    (EPUB CFI 1.1 §3.1.1: child *elements* get even indices starting at 2, and the
 *    leading step references the `<spine>` element). `/6/4` is the second spine
 *    item, i.e. ordinal 1. The spec's own worked example agrees: its `chapter01` is
 *    the second `itemref` and its CFI is `/6/4`.
 *  - **What cannot map.** Everything after the `!` — `!/4/88`, or the start
 *    location of a range CFI — is a position *inside* the spine item. Reader Kit
 *    positions a page with an opaque `domPos` string that only the kit itself
 *    mints: the SDK defines no grammar for it and offers no constructor, and there
 *    is no CFI bridge anywhere in `@hms.core.readerservice.*` (`grep -i cfi` over
 *    those declarations returns nothing). The CFI's `:66` character offset is a
 *    UTF-16 code-unit index with no evidence of compatibility with whatever the kit
 *    means by a position. **So a position that arrived as a CFI can restore the
 *    chapter, never the page.** Faking the finer part would be a guess presented as
 *    a position.
 *
 * A range CFI is reduced to its **start** location (§3.4 gives a range's start as
 * the position of the annotation), so `epubcfi(/6/2282!/4,/88,/110/1:66)` yields
 * ordinal 1140 — the same as `epubcfi(/6/2282)`.
 *
 * The reverse direction writes the coarsest CFI that is still true: a spine-level
 * CFI, `epubcfi(/6/{2n})`. `ReadAny`'s `resolveCFI` accepts that form
 * (`packages/foliate-js/epubcfi.js`, `fake.fromIndex`), so a desktop client lands
 * in the right chapter instead of at the start of the book.
 *
 * `/6` is the spine element — the third element child of `<package>` (metadata=2,
 * manifest=4, spine=6). That is fixed in practice rather than by the grammar, so a
 * CFI that does not start there is refused rather than reinterpreted.
 */

/** The spine step inside `<package>`: metadata=2, manifest=4, spine=6. */
const PACKAGE_SPINE_STEP: number = 6;

/** Length of the `epubcfi(` prefix. */
const CFI_PREFIX_LENGTH: number = 8;

/** Returned by `spineOrdinalFromCfi` when a CFI yields no usable spine pointer. */
export const CFI_ORDINAL_UNKNOWN: number = -1;

/**
 * The 0-based spine ordinal a CFI points at, or `CFI_ORDINAL_UNKNOWN`.
 *
 * Returning a sentinel rather than `0` is the whole point: ordinal 0 is a real
 * chapter (the first one), so "unusable" must be distinguishable from it. Callers
 * are expected to log the sentinel and fall back to the book's own first spine item
 * rather than open at an assumed position.
 *
 * Rejected, deliberately: a missing or malformed wrapper, a path that does not
 * start with the spine step, an odd or zero `N` (those are not element indices),
 * and a CFI with too few steps to contain a spine pointer.
 */
export function spineOrdinalFromCfi(cfi: string): number {
  const inner: string = cfiInner(cfi);
  if (inner.length === 0) {
    return CFI_ORDINAL_UNKNOWN;
  }
  // A range CFI's *start* location is the position; everything after the first
  // top-level comma is a length or an end point.
  const start: string = cfiStartLocation(inner);
  const bang: number = start.indexOf('!');
  const path: string = bang >= 0 ? start.substring(0, bang) : start;
  const steps: number[] = cfiSteps(path);
  if (steps.length < 2) {
    return CFI_ORDINAL_UNKNOWN;
  }
  if (steps[0] !== PACKAGE_SPINE_STEP) {
    return CFI_ORDINAL_UNKNOWN;
  }
  const step: number = steps[1];
  if (!Number.isInteger(step) || step < 2 || step % 2 !== 0) {
    return CFI_ORDINAL_UNKNOWN;
  }
  return step / 2 - 1;
}

/**
 * The spine-level CFI for a 0-based Reader Kit spine index: `epubcfi(/6/{2(n+1)})`.
 *
 * Returns `''` when the index cannot describe a spine item (negative, fractional,
 * `NaN`, infinite). An empty return means "no CFI can be computed", which callers
 * must treat as "leave whatever a peer wrote alone" rather than as "write nothing".
 */
export function spineCfiFor(spineIndex: number): string {
  if (!Number.isInteger(spineIndex) || spineIndex < 0) {
    return '';
  }
  return `epubcfi(/6/${(spineIndex + 1) * 2})`;
}

/**
 * The inside of the `epubcfi(...)` wrapper.
 *
 * A bare path (`/6/4!/2`) is accepted as well, because `ReadAny`'s own helper
 * builds CFIs from path strings and a value that lost its wrapper somewhere is
 * still readable; anything that is neither is rejected. An unterminated wrapper is
 * rejected rather than trimmed, because the missing `)` may be hiding the rest of a
 * longer, unrelated string.
 */
function cfiInner(cfi: string): string {
  const trimmed: string = cfi.trim();
  if (trimmed.startsWith('epubcfi(')) {
    if (!trimmed.endsWith(')')) {
      return '';
    }
    return trimmed.substring(CFI_PREFIX_LENGTH, trimmed.length - 1);
  }
  return trimmed.startsWith('/') ? trimmed : '';
}

/**
 * The start location of a CFI: everything before the first comma that is not
 * inside an assertion bracket.
 *
 * `epubcfi(/6/2282!/4,/88,/110/1:66)` → `/6/2282!/4`. Bracket depth is tracked
 * because assertions (`[chap01ref]`) are the one place a comma may legitimately
 * appear before the range separator.
 */
function cfiStartLocation(inner: string): string {
  let depth: number = 0;
  for (let i = 0; i < inner.length; i++) {
    const ch: string = inner.charAt(i);
    if (ch === '[') {
      depth++;
    } else if (ch === ']') {
      if (depth > 0) {
        depth--;
      }
    } else if (ch === ',' && depth === 0) {
      return inner.substring(0, i);
    }
  }
  return inner;
}

/**
 * The integer steps of the leading package path, in order.
 *
 * `/6/4[chap01ref]` → `[6, 4]`; `/6/4!/2` → `[6, 4]` (the content path is not part
 * of this). Parsing stops at the first position that is not `/` followed by digits,
 * so a malformed step truncates the list instead of being skipped over — a skipped
 * step would silently change which number is read as the spine index.
 */
function cfiSteps(path: string): number[] {
  const steps: number[] = [];
  let i: number = 0;
  while (i < path.length) {
    if (path.charAt(i) !== '/') {
      break;
    }
    i++;
    const start: number = i;
    while (i < path.length) {
      const digit: string = path.charAt(i);
      if (digit < '0' || digit > '9') {
        break;
      }
      i++;
    }
    if (i === start) {
      break;
    }
    steps.push(Number.parseInt(path.substring(start, i), 10));
    // An assertion attached to this step, e.g. `[chap01ref]`, is not a step.
    if (i < path.length && path.charAt(i) === '[') {
      const close: number = path.indexOf(']', i);
      if (close < 0) {
        break;
      }
      i = close + 1;
    }
    if (i < path.length && path.charAt(i) === '!') {
      break;
    }
  }
  return steps;
}
