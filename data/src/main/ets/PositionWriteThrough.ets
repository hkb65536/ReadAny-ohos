/**
 * Write a pulled reading position through to the reader's local cache.
 *
 * ## The defect this exists for
 *
 * A v1 pull merges each `books` row **as a whole** and rewrites only the columns the peer
 * actually carried. A desktop client has no `current_spine` / `current_dom_pos` columns at
 * all, so when its (newer) row wins, `progress` and `current_cfi` are updated while this
 * device's own spine/domPos pair survives untouched. The row is then holding two
 * contradictory positions: a fresh CFI at 80 % beside a stale pair at 70 %.
 *
 * `resolveOpenPosition` reads the local cache first — deliberately, because no column
 * records when a position was written (see its comment) — so the reader resumed at the
 * stale pair, and on the way out `persistPosition` wrote that pair back over the peer's
 * 80 % with a fresh `updated_at`. The next pass then took the phone's 70 % as the newest
 * row and destroyed the desktop's 80 % too. That last step is the data loss: the bug did
 * not merely show the wrong page, it propagated the older position back.
 *
 * ## The rule, and why it needs no new timestamp
 *
 * The engine has already decided that this row wins the **row-level** last-writer-wins
 * comparison (`shouldApplyRemoteRecord`) before it calls `upsert`. So "this row won" is a
 * settled fact, and reconciling the cache with what the winning row carries is not a
 * second comparison — it is using the existing decision:
 *
 *  - the row carries a usable spine/domPos pair (`hasSyncedPositionColumns`, the same
 *    predicate `resolveOpenPosition` applies to the columns) → the cache is **set** to
 *    that pair, with the row's `progress` as the fraction;
 *  - no usable pair, but a non-empty `current_cfi` → the cache is **cleared**, so
 *    `resolveOpenPosition` falls through to the book row and the reader opens from
 *    `book.currentCfi`. This is the 牧神记 case: the desktop row carries only a CFI, and
 *    the stale local pair is exactly what must stop winning;
 *  - neither → the cache is **left alone**. A peer that has no position says nothing
 *    about this device's.
 *
 * A row that **loses** never reaches this class at all. `SyncV1` calls the record writer
 * only after the comparison returned true (and only wraps the call in a `try` whose
 * `catch` skips the row), so "never destroy a local position with a stale peer" is a
 * property of where this code sits, not a promise it has to keep by checking something.
 * There is deliberately no comparison here: `books.updated_at` is not a position
 * timestamp and `last_opened_at` is not one either, which is the reason
 * `resolveOpenPosition` needs this seam in the first place.
 *
 * ## Why a writer decorator rather than a hook inside `SyncV1`
 *
 * `SyncV1` is table-generic and must stay that way. The only thing it already tells the
 * writer is "this row won, write it" — so reconciling the reader's cache with the row
 * that was just written is the reader's business, expressed against the same port.
 * `SyncV1.ets` is therefore unchanged by this fix: no new parameter, no book-shaped
 * knowledge, and `book_groups` / `highlights` / `notes` / `bookmarks` go through the
 * pass-through methods below untouched.
 *
 * ## Scope: the v1 apply path only
 *
 * The v2 engine applies a book through `Books.applyRemoteBook`, a different path with its
 * own merge, and is **not** covered by this class. A v2 server can produce the same
 * contradiction. Stated rather than implied.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import type { Database } from './Database';
import {
  ReaderStore,
  hasSyncedPositionColumns,
} from './ReaderStore';
import type { ReadingPosition } from './ReaderStore';
import type { V1LocalState, V1RecordWriter, WireRow } from './SyncV1';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatPositionWriteThrough';

/** What a winning `books` row says about the local cache. */
export const PULLED_POSITION_IGNORE: number = 0;
export const PULLED_POSITION_SET: number = 1;
export const PULLED_POSITION_CLEAR: number = 2;

/**
 * Decide what to do with the local cache from the three position columns of a winning row.
 *
 * Pure and exported so the rule can be evaluated from its shipped source: the branches are
 * the whole fix, and a cache that is cleared when it should have been seeded (or left
 * stale when it should have been cleared) is silent — the reader merely opens at the old
 * page, which is the bug this file exists for.
 */
export function pulledPositionAction(spine: number, domPos: string, cfi: string): number {
  if (hasSyncedPositionColumns(spine, domPos)) {
    return PULLED_POSITION_SET;
  }
  if (cfi.length > 0) {
    return PULLED_POSITION_CLEAR;
  }
  return PULLED_POSITION_IGNORE;
}

/**
 * A column value as a number, or the fallback.
 *
 * A wire row's cells are `Object | null`, and a peer may legitimately have sent `null`
 * (its own column had no value). A string is accepted because the same row reaches this
 * module after a JSON round trip, where a numeric column that was stored as text comes
 * back as text.
 */
function numberColumn(record: WireRow, key: string, fallback: number): number {
  const value: Object | null | undefined = record[key];
  if (typeof value === 'number' && !Number.isNaN(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

/** A column value as a string, or the fallback. `null` and absent both mean "empty". */
function stringColumn(record: WireRow, key: string, fallback: string): string {
  const value: Object | null | undefined = record[key];
  return typeof value === 'string' ? value : fallback;
}

/**
 * The record writer the v1 engine is constructed with: the real one, plus the reader's
 * cache kept in step with every `books` row that wins.
 *
 * `upsert` is the only method with behaviour of its own. Every other method is a
 * pass-through, and that is on purpose: the merge rules, the tombstones and the column
 * filter are `SyncV1`'s, and a decorator that also decided about them would be a second
 * place for them to live.
 */
export class PositionWriteThroughWriter implements V1RecordWriter {
  private readonly inner: V1RecordWriter;
  private readonly store: ReaderStore;

  constructor(inner: V1RecordWriter, db: Database) {
    this.inner = inner;
    this.store = new ReaderStore(db);
  }

  columnsOf(table: string): Promise<Set<string>> {
    return this.inner.columnsOf(table);
  }

  loadStates(
    table: string,
    pk: string,
    timestampCol: string,
    ids: string[],
  ): Promise<Map<string, V1LocalState>> {
    return this.inner.loadStates(table, pk, timestampCol, ids);
  }

  remove(table: string, pk: string, id: string): Promise<void> {
    return this.inner.remove(table, pk, id);
  }

  rememberTombstone(
    table: string,
    id: string,
    deletedAt: number,
    deviceId: string,
  ): Promise<void> {
    return this.inner.rememberTombstone(table, id, deletedAt, deviceId);
  }

  /**
   * Write the row, then reconcile the reader's cache with it.
   *
   * **The row is written first.** "Applied" has to mean the row is on disk before the cache
   * follows it, or a cache write that succeeded while the row write failed would make this
   * device resume at a position no row carries.
   *
   * **The reconcile is table-gated to `books`** and its failure is swallowed (logged, not
   * rethrown). Rethrowing would be worse than useless: `SyncV1` catches a throwing `upsert`
   * and counts the row as *skipped*, so a failed cache write would report a row that was
   * successfully applied as skipped on every pass, and the real cause would never surface.
   */
  async upsert(table: string, pk: string, record: WireRow): Promise<void> {
    await this.inner.upsert(table, pk, record);
    if (table !== 'books') {
      return;
    }
    try {
      await this.reconcilePosition(record);
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        'could not reconcile the local position for book %{public}s after a winning pull: '
        + '%{public}s',
        shortId(stringColumn(record, 'id', '')), String(err));
    }
  }

  /** Apply `pulledPositionAction` to the local `sync_metadata` entry. */
  private async reconcilePosition(record: WireRow): Promise<void> {
    const bookId: string = stringColumn(record, 'id', '');
    if (bookId.length === 0) {
      return;
    }
    const spine: number = numberColumn(record, 'current_spine', 0);
    const domPos: string = stringColumn(record, 'current_dom_pos', '');
    const cfi: string = stringColumn(record, 'current_cfi', '');
    const action: number = pulledPositionAction(spine, domPos, cfi);
    if (action === PULLED_POSITION_IGNORE) {
      return;
    }
    if (action === PULLED_POSITION_CLEAR) {
      // Clearing makes `loadPosition` return the empty sentinel, so `resolveOpenPosition`
      // falls through to the row the CFI came from — the same path a fresh install takes.
      await this.store.clearPosition(bookId);
      hilog.info(DOMAIN, TAG,
        'cleared the local position for book %{public}s: the winning row carries only a CFI',
        shortId(bookId));
      return;
    }
    const position: ReadingPosition = {
      spineIndex: spine,
      domPos: domPos,
      fraction: numberColumn(record, 'progress', 0),
      chapterTitle: '',
      // Not `record.updated_at`: that is when the peer last edited the row, not when it
      // wrote the position, and asserting it here would re-introduce exactly the mistake
      // `resolveOpenPosition` documents.
      updatedAt: 0,
    };
    await this.store.savePosition(bookId, position);
    hilog.info(DOMAIN, TAG,
      'adopted the winning pull position for book %{public}s: spine %{public}s, fraction %{public}s',
      shortId(bookId), String(spine), String(position.fraction));
  }
}

/** A device id or book id, shortened for a log line. */
function shortId(id: string): string {
  return id.length > 8 ? id.substring(0, 8) : id;
}
