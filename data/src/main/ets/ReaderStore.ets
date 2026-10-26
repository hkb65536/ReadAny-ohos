/**
 * Reading settings and position.
 *
 * Reader Kit has its own locator: a reading position is a `(spineIndex, domPos)`
 * pair, not an EPUB CFI. Positions therefore restore differently in each direction,
 * and the difference is worth stating plainly:
 *
 *  - **This client to this client — the same reading position.** The pair is written
 *    to `books.current_spine` / `books.current_dom_pos`, which are ordinary synced
 *    columns, so another InkBoat install lays out from the same position (and shows
 *    the same page when its reader settings match — pagination is the kit's, so a
 *    different font size moves page boundaries but not the position). This is the
 *    case the reader used to miss entirely: the columns were written and synced but
 *    never read back, so every book opened at page 1. `resolveOpenPosition` is the
 *    fix.
 *  - **A CFI from a ReadAny client — chapter-accurate, not page-accurate.** Reader
 *    Kit's `domPos` is an opaque string that only the kit can mint: the SDK defines
 *    no grammar for it, offers no constructor, and contains no CFI bridge at all.
 *    A peer's CFI therefore identifies the spine item it names and no more, and the
 *    reader opens at that chapter (`startPlay(index, '')`). The page inside the
 *    chapter is not recoverable, and guessing one would move the reader somewhere
 *    the file does not say.
 *  - **This client to ReadAny — chapter-accurate too.** A saved position writes a
 *    spine-level CFI, `epubcfi(/6/{2n})`, which the desktop resolves into the same
 *    chapter.
 *
 * So `books.current_cfi` is written now, and a peer's CFI is never overwritten with
 * an empty string: when no CFI can be computed, the peer's value is left alone.
 *
 * The local `sync_metadata` entry stays the per-device record of the exact
 * `(spineIndex, domPos)` pair and is what `loadPosition` reads, but `sync_metadata`
 * lives inside the app sandbox and is removed with the app — it is not synced.
 * Surviving a reinstall is the book row's job, which is why the two are combined in
 * `resolveOpenPosition`.
 *
 * **A pull that wins writes through to that cache.** Merging a peer's `books` row only
 * rewrites the columns the peer sent, so a desktop row (which has no
 * `current_spine` / `current_dom_pos` columns at all) can leave this device's stale pair
 * beside a fresh `progress` and CFI. `resolveOpenPosition` prefers the local pair — for
 * the reason stated there — so without the write-through the next open would resume at
 * the stale page and write it back over the peer's newer progress. `PositionWriteThrough`
 * reconciles the cache with the row that won, which is why the preference above is only
 * "until the next pull applies a winning row".
 *
 * Settings are persisted alongside, because a reader that forgets the font size
 * between sessions is not usable.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import type { HighlightColor } from 'core';
import type { Database } from './Database';
import type { Book } from './Types';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatReaderStore';

/**
 * The reader's own persisted settings.
 *
 * **The page's appearance is deliberately not here.** This interface used to carry
 * `themeColor`, `fontColor` and `nightMode` alongside the application theme, which is what
 * made the reader's colours a second source of truth: `ThemeMode` painted the window while
 * these three painted the page, and nothing kept the two in step. The symptom was exactly
 * that — the sepia theme showed a white reader, and dark mode showed dark text.
 *
 * The page colours now come from one place, `readerAppearance(mode)` in
 * `entry/src/main/ets/theme/Theme.ets`, derived from the application theme. These three
 * fields are therefore **retired**: they are not read here, not written here, and
 * `loadSettings` rewrites a blob that still contains them so pre-change state cannot
 * survive (`RETIRED_SETTINGS_KEYS`).
 *
 * What is left is genuinely the reader's own: how the text is set, and the two reader-local
 * choices — flip mode and the default highlight colour — that no other screen owns.
 * `themeBgImg` stays because it is a page *background image*, which a colour palette cannot
 * express; it is empty, nothing sets it, and it is still handed to the kit, so it is neither
 * written-but-unread nor read-but-unwritten.
 */
export interface ReaderSettings {
  fontSize: number;
  /** Multiplier, matching Reader Kit's `lineHeight` as a coefficient. */
  lineHeight: number;
  fontWeight: number;
  /** Empty means "use the system default font". */
  fontPath: string;
  /** Background image path, empty for none. Not an appearance colour; see above. */
  themeBgImg: string;
  /** Reader Kit's flip animation mode. */
  flipMode: string;
  /** Default colour offered in the selection popover. */
  defaultHighlightColor: HighlightColor;
}

/**
 * Settings keys this build no longer owns, kept named so the purge below is one list rather
 * than three `includes` calls that can fall out of step with the interface.
 *
 * `nightMode` is the one that matters on a device that has been read on: a stored
 * `nightMode: true` is exactly what the reader used to switch its page to a dark palette,
 * and if it were still honoured the old behaviour would survive this fix for every existing
 * user while a fresh install looked correct.
 */
const RETIRED_SETTINGS_KEYS: string[] = ['themeColor', 'fontColor', 'nightMode'];

export const MIN_FONT_SIZE: number = 12;
export const MAX_FONT_SIZE: number = 64;
export const MIN_LINE_HEIGHT: number = 1.2;
export const MAX_LINE_HEIGHT: number = 2.5;

/**
 * Defaults for the reader's own settings.
 *
 * These used to include a page background and text colour, described as "chosen to match the
 * ReadAny clients". They did not: ReadAny has no reader theme setting at all — its reader
 * reads the application theme (`FoliateViewer.tsx:111-119`) — so the pair here was this
 * app's own invention and the thing that disconnected the page from the theme. Appearance
 * is now derived from `themeMode`; see `ReaderSettings`.
 */
export function defaultReaderSettings(): ReaderSettings {
  return {
    fontSize: 18,
    lineHeight: 1.6,
    fontWeight: 400,
    fontPath: '',
    themeBgImg: '',
    flipMode: '0',
    defaultHighlightColor: 'yellow',
  };
}

/** Field-by-field copy; ArkTS has no object spread. */
export function copySettings(source: ReaderSettings): ReaderSettings {
  return {
    fontSize: source.fontSize,
    lineHeight: source.lineHeight,
    fontWeight: source.fontWeight,
    fontPath: source.fontPath,
    themeBgImg: source.themeBgImg,
    flipMode: source.flipMode,
    defaultHighlightColor: source.defaultHighlightColor,
  };
}

/** Clamp a font size into the supported range. */
export function clampFontSize(value: number): number {
  if (Number.isNaN(value) || value < MIN_FONT_SIZE) {
    return MIN_FONT_SIZE;
  }
  return value > MAX_FONT_SIZE ? MAX_FONT_SIZE : Math.round(value);
}

/** Clamp a line-height coefficient into the supported range. */
export function clampLineHeight(value: number): number {
  if (Number.isNaN(value) || value < MIN_LINE_HEIGHT) {
    return MIN_LINE_HEIGHT;
  }
  return value > MAX_LINE_HEIGHT ? MAX_LINE_HEIGHT : value;
}

/**
 * Reading position in the reader's own coordinate system.
 *
 * `fraction` is stored alongside because the shelf's progress bar needs a number
 * without opening the book, and computing it from `(spineIndex, chapterCount)`
 * would only be an approximation of what the reader last reported.
 */
export interface ReadingPosition {
  /**
   * Reader Kit spine index, or `NO_POSITION_SPINE` when there is no stored
   * position at all.
   *
   * A sentinel is necessary rather than convenient: **spine index `0` is a real
   * position** (the book's first spine item), so the empty position cannot use it
   * without making "no position" indistinguishable from "position zero". Callers ask
   * `spineIndex >= 0` to mean "a position exists".
   */
  spineIndex: number;
  domPos: string;
  fraction: number;
  /** Chapter title for the header, when the TOC provided one. */
  chapterTitle: string;
  updatedAt: number;
}

/**
 * `spineIndex` value meaning "no stored position".
 *
 * Negative rather than a separate flag on purpose: the reader already branches on
 * `initialSpine >= 0` to choose between a stored position and its own first-page
 * fallback, so the sentinel is the shape the consumer was written for. What was
 * missing was a producer that honours it.
 */
export const NO_POSITION_SPINE: number = -1;

export function emptyPosition(): ReadingPosition {
  return {
    spineIndex: NO_POSITION_SPINE,
    domPos: '',
    fraction: 0,
    chapterTitle: '',
    updatedAt: 0,
  };
}

/** True when a stored position is a real one rather than the empty sentinel. */
export function hasPosition(position: ReadingPosition): boolean {
  return position.spineIndex >= 0;
}

/**
 * The position a book should open at.
 *
 * **A local position wins when there is one; the synced columns on the book row are
 * the fallback.** That order is a choice, and it is made because no timestamp in the
 * schema can honestly say which of the two was written later:
 *
 *  - `books.updated_at` is bumped by every edit to the row — a chapter count, a tag,
 *    a cover — and by every remote pull, so a newer `updated_at` does not mean a
 *    newer position.
 *  - `books.last_opened_at` looks like a position timestamp but is not one. A
 *    ReadAny client has no `current_spine` / `current_dom_pos` columns at all; it
 *    writes `current_cfi` and `last_opened_at` together on a throttled progress save
 *    (`packages/app/src/components/reader/ReaderView.tsx`) and it bumps
 *    `last_opened_at` alone when a book is merely opened or restored
 *    (`app-expo/src/screens/ReaderScreen.tsx`). Using it as the synced position's
 *    timestamp would let a desktop *open* make a stale chapter look newer than the
 *    page the user last read here.
 *
 * The tradeoff, stated rather than hidden: a book already read on this device keeps
 * this device's position even when a peer has read further, because the peer's
 * position arrives in columns whose write time is not recorded. **That preference lasts
 * only until the next pull applies a winning row for this book**: the local entry is a
 * cache, and `PositionWriteThrough` reconciles it with the position the winning row
 * carries (setting it when the row has a usable pair, clearing it when the row has only
 * a CFI). The one thing that must never happen — and does not — is a local position
 * being destroyed by a row that *lost* the merge: the engine calls the writer only for
 * a row that won. What the fallback below fixes is the case that was broken — a fresh
 * install, a reinstall, or any device that has never opened the book now starts at the
 * position a peer synced instead of at page 1.
 */
export function resolveOpenPosition(local: ReadingPosition, book: Book): ReadingPosition {
  if (hasPosition(local)) {
    return local;
  }
  if (!hasSyncedPosition(book)) {
    return emptyPosition();
  }
  return {
    spineIndex: book.currentSpine,
    domPos: book.currentDomPos,
    fraction: book.progress,
    chapterTitle: '',
    // Deliberately not `book.lastOpenedAt`: the row does not record when its
    // position columns were written, and asserting one here would repeat exactly the
    // mistake this rule exists to avoid.
    updatedAt: 0,
  };
}

/**
 * True when the synced position columns actually hold a position.
 *
 * The distinction is load-bearing because `current_spine` defaults to `0` in the
 * schema, so by the number alone a row that never carried a position looks like one
 * whose position is the first spine item. A `domPos` is only ever written alongside a
 * real page report and a positive spine index cannot be the column default, so either
 * is evidence that a position was written.
 *
 * The one remaining case — the first spine item with an empty `domPos` — is treated
 * as no usable synced position. The fallback then opens at the book's own first spine
 * item, which is the same place, and a peer's CFI is not masked by an ambiguous zero.
 */
export function hasSyncedPosition(book: Book): boolean {
  return hasSyncedPositionColumns(book.currentSpine, book.currentDomPos);
}

/**
 * The same test against the two columns rather than a book row.
 *
 * Split out because the two producers must not drift: `resolveOpenPosition` reads the
 * columns off the row, while the write-through that keeps the local cache in step with a
 * winning pull (`PositionWriteThrough`) has only the wire record. Two copies of
 * `domPos.length > 0 || spine > 0` would disagree the day one of them changed.
 */
export function hasSyncedPositionColumns(spine: number, domPos: string): boolean {
  return domPos.length > 0 || spine > 0;
}

/** `sync_metadata` keys owned by the reader. */
const KEY_SETTINGS: string = 'reader_settings';
const PREFIX_POSITION: string = 'reader_position:';

/**
 * Reading state persistence.
 *
 * Settings are a single JSON blob because they are always read and written
 * together and there is no benefit to per-field keys. Positions are keyed per book
 * because a user has many books and only one of them is open.
 */
export class ReaderStore {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /**
   * Load settings, falling back to defaults for any field that is unreadable.
   *
   * **A blob written before the theme move is migrated here, once.** A stored blob may
   * still carry `themeColor`, `fontColor` and `nightMode` from the build where the reader
   * owned its own appearance — on a device that has been read on, `nightMode: true` is the
   * normal case. Those keys are not read any more (the interface no longer has them, so
   * `settingsFromRecord` cannot pick them up), which is what makes the fix apply to an
   * existing install rather than only to a fresh one. The rewrite below is the second half:
   * it removes the dead keys so the stored state matches the schema instead of carrying
   * three values nothing reads and a reader-only night flag that looks authoritative.
   *
   * The write is guarded by the presence of a retired key, so it happens at most once per
   * device, and a failure is not fatal — the in-memory settings are already correct.
   */
  async loadSettings(): Promise<ReaderSettings> {
    const raw: string = await this.db.getMeta(KEY_SETTINGS);
    if (raw.length === 0) {
      return defaultReaderSettings();
    }
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed === null || typeof parsed !== 'object') {
        return defaultReaderSettings();
      }
      const record: Record<string, Object> = parsed as Record<string, Object>;
      const settings: ReaderSettings = settingsFromRecord(record);
      if (hasRetiredSettings(record)) {
        try {
          await this.saveSettings(settings);
        } catch (err) {
          // Non-fatal on purpose: the settings returned are already the migrated ones, so
          // the reader is correct for this session and the next load simply retries. Logged
          // rather than swallowed because a purge that keeps failing means the stored blob
          // never matches the schema, and that is invisible without a line here.
          hilog.warn(DOMAIN, TAG, 'retired reader settings not purged: %{public}s', String(err));
        }
      }
      return settings;
    } catch (err) {
      // A corrupt blob must not make the reader unusable; defaults are always safe.
      return defaultReaderSettings();
    }
  }

  async saveSettings(settings: ReaderSettings): Promise<void> {
    const record: Record<string, Object> = {};
    record['fontSize'] = clampFontSize(settings.fontSize);
    record['lineHeight'] = clampLineHeight(settings.lineHeight);
    record['fontWeight'] = settings.fontWeight;
    record['fontPath'] = settings.fontPath;
    record['themeBgImg'] = settings.themeBgImg;
    record['flipMode'] = settings.flipMode;
    record['defaultHighlightColor'] = settings.defaultHighlightColor;
    await this.db.setMeta(KEY_SETTINGS, JSON.stringify(record));
  }

  /**
   * Load the last position for a book, or the empty sentinel when there is none.
   *
   * The header explains why the returned `spineIndex` may be negative: this is a
   * local-only read (`sync_metadata`), and the synced columns on the book row are
   * combined with it by `resolveOpenPosition` rather than here, so that this method
   * keeps one job.
   */
  async loadPosition(bookId: string): Promise<ReadingPosition> {
    const raw: string = await this.db.getMeta(`${PREFIX_POSITION}${bookId}`);
    if (raw.length === 0) {
      return emptyPosition();
    }
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed === null || typeof parsed !== 'object') {
        return emptyPosition();
      }
      return positionFromRecord(parsed as Record<string, Object>);
    } catch (err) {
      return emptyPosition();
    }
  }

  async savePosition(bookId: string, position: ReadingPosition): Promise<void> {
    const record: Record<string, Object> = {};
    record['spineIndex'] = position.spineIndex;
    record['domPos'] = position.domPos;
    record['fraction'] = position.fraction;
    record['chapterTitle'] = position.chapterTitle;
    record['updatedAt'] = position.updatedAt;
    await this.db.setMeta(`${PREFIX_POSITION}${bookId}`, JSON.stringify(record));
  }

  /** Forget a book's position, for when the book itself is removed. */
  async clearPosition(bookId: string): Promise<void> {
    await this.db.setMeta(`${PREFIX_POSITION}${bookId}`, '');
  }
}

function settingsFromRecord(record: Record<string, Object>): ReaderSettings {
  const defaults: ReaderSettings = defaultReaderSettings();
  return {
    fontSize: clampFontSize(numberIn(record, 'fontSize', defaults.fontSize)),
    lineHeight: clampLineHeight(numberIn(record, 'lineHeight', defaults.lineHeight)),
    fontWeight: numberIn(record, 'fontWeight', defaults.fontWeight),
    fontPath: stringIn(record, 'fontPath', defaults.fontPath),
    themeBgImg: stringIn(record, 'themeBgImg', defaults.themeBgImg),
    flipMode: stringIn(record, 'flipMode', defaults.flipMode),
    defaultHighlightColor: colorIn(record, 'defaultHighlightColor', defaults.defaultHighlightColor),
  };
}

/**
 * True when a stored blob still carries a field this build retired.
 *
 * Presence, not truthiness: a stored `nightMode: false` and a stored `themeColor` of
 * any value are both stale, and leaving them behind is how a later change re-adopts a key
 * that the reader no longer owns.
 */
function hasRetiredSettings(record: Record<string, Object>): boolean {
  for (const key of RETIRED_SETTINGS_KEYS) {
    if (record[key] !== undefined) {
      return true;
    }
  }
  return false;
}

function positionFromRecord(record: Record<string, Object>): ReadingPosition {
  return {
    // A record with no readable `spineIndex` is not a position; defaulting it to `0`
    // would turn a corrupt entry into "the first page", which is the same confusion
    // the sentinel exists to remove.
    spineIndex: numberIn(record, 'spineIndex', NO_POSITION_SPINE),
    domPos: stringIn(record, 'domPos', ''),
    fraction: numberIn(record, 'fraction', 0),
    chapterTitle: stringIn(record, 'chapterTitle', ''),
    updatedAt: numberIn(record, 'updatedAt', 0),
  };
}

function numberIn(record: Record<string, Object>, key: string, fallback: number): number {
  const value: Object | undefined = record[key];
  if (typeof value === 'number' && !Number.isNaN(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

function stringIn(record: Record<string, Object>, key: string, fallback: string): string {
  const value: Object | undefined = record[key];
  return typeof value === 'string' ? value : fallback;
}

const HIGHLIGHT_COLOR_NAMES: string[] =
  ['red', 'yellow', 'green', 'blue', 'pink', 'purple', 'violet'];

function colorIn(
  record: Record<string, Object>,
  key: string,
  fallback: HighlightColor,
): HighlightColor {
  const value: Object | undefined = record[key];
  if (typeof value === 'string' && HIGHLIGHT_COLOR_NAMES.includes(value)) {
    return value as HighlightColor;
  }
  return fallback;
}
