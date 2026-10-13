/**
 * Per-row last-write-wins decision.
 *
 * Ported from ReadAny `packages/core/src/sync/simple-sync.ts`
 * (`shouldApplyRemoteRecord`). Both clients must reach the same verdict for the
 * same pair of rows, otherwise two devices keep flip-flopping each other's
 * edits on every sync pass.
 *
 * A synced row is a flat object whose keys are SQLite column names. ArkTS has
 * no index-signature types, so callers hand over an explicit `field(name)`
 * reader instead of the raw object.
 */

import type { FieldReader } from 'core';
import { MAX_FUTURE_TOMBSTONE_SKEW_MS } from './SyncConstants';

/**
 * Field reader over one remote/local row. Re-exported from `core` for callers of
 * this module; the canonical definition lives there because `data` needs the same
 * abstraction and may not depend on `sync`.
 */
export type { FieldReader };

/** Local counterpart of a remote row, as recorded before the merge. */
export interface LocalRecordState {
  /** Value of the table's timestamp column (`updated_at`, or `created_at` for messages). */
  timestamp: number;
  /** `deleted_at`, or `null` when the local row is alive. */
  deletedAt: number | null;
}

/**
 * Explicit constructor for `LocalRecordState`.
 *
 * ArkTS rejects an inline object literal for a parameter typed as an interface
 * (`arkts-no-untyped-obj-literals`), so every call site goes through this.
 */
export function localRecordState(timestamp: number, deletedAt: number | null): LocalRecordState {
  return { timestamp: timestamp, deletedAt: deletedAt };
}

/** Coerce a remote `deleted_at` cell to a number or `null`. */
export function normalizeDeletedAt(value: string | number | boolean | null | undefined): number | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? null : parsed;
  }
  return null;
}

/**
 * True when the remote row should overwrite the local one.
 *
 * Rules, in order:
 *  1. No local row at all → apply.
 *  2. Remote timestamp strictly newer → apply.
 *  3. Remote timestamp strictly older → skip.
 *  4. Timestamps tie → skip, unless both sides carry a `deleted_at` and the
 *     remote deletion is newer. That tie-break stops two devices from
 *     permanently disagreeing about whether a book is alive or deleted.
 */
export function shouldApplyRemoteRecord(
  record: FieldReader,
  timestampColumn: string,
  local: LocalRecordState | undefined,
): boolean {
  if (local === undefined) {
    return true;
  }

  const remoteRaw: string | number | boolean | null | undefined = record.field(timestampColumn);
  const remoteTs: number = typeof remoteRaw === 'number' ? remoteRaw : Number(remoteRaw);
  if (Number.isNaN(remoteTs)) {
    return false;
  }

  if (remoteTs > local.timestamp) {
    return true;
  }
  if (remoteTs < local.timestamp) {
    return false;
  }

  // Tie. Only a *newer delete marker* with a *different* value may win.
  const remoteDeletedAt: number | null = normalizeDeletedAt(record.field('deleted_at'));
  const localDeletedAt: number | null = local.deletedAt;
  if (remoteDeletedAt === localDeletedAt) {
    return false;
  }
  return (remoteDeletedAt ?? 0) > (localDeletedAt ?? 0);
}

/**
 * Tombstone application rule: delete a local row only when the remote deletion
 * is at least as new as the local row.
 *
 * A local row edited *after* the remote deletion is kept — it will travel back
 * up on the next push as a resurrection. Ported from `applyTombstoneMap`.
 *
 * This is only the ordering half of the decision. Every caller must also pass
 * `isPlausibleTombstone` first; the two are separate functions so this one stays
 * a faithful port of the reference comparison (and `>=` keeps its exact meaning)
 * while the sanity bound lives beside it.
 */
export function shouldApplyTombstone(deletedAt: number, localUpdatedAt: number, forceApply: boolean): boolean {
  if (forceApply) {
    return true;
  }
  return deletedAt >= localUpdatedAt;
}

/**
 * Sanity bound on a remote deletion timestamp: reject deletions claimed to have
 * happened implausibly far in the future.
 *
 * This is the destructive half of the guard. `shouldApplyTombstone` only asks
 * whether a tombstone is *newer* than the local row, so a fabricated timestamp of
 * `9e15` (year ~287396) satisfies it trivially against every real `updated_at`.
 * Applying such a tombstone deletes the row, writes a sticky local tombstone that
 * stops the deletion from being undone, and — for a book — cascades into every
 * highlight, note and bookmark it owns. A re-pull cannot restore any of it.
 *
 * `now` is passed in rather than read here so the rule is pure and testable, and
 * so a caller deciding about one remote file uses a single consistent clock.
 *
 * Fails closed by *ignoring* the tombstone, never by applying it: the local row
 * survives, the remote file is left untouched, and the same verdict is reached on
 * the next pass. A legitimate past or near-present deletion is unaffected —
 * `deletedAt <= now + MAX_FUTURE_TOMBSTONE_SKEW_MS` holds for every honest value,
 * including a year-old deletion from a device that has been offline, and the
 * `forceApply` / `>=` behaviour of the callers is unchanged.
 *
 * `Number.isFinite` rejects `NaN` and `Infinity` as well as values past the bound,
 * so it does not matter whether the timestamp arrived as a JSON number, as a
 * numeric string through `numberCell`, or via `toNumberMap`.
 */
export function isPlausibleTombstone(deletedAt: number, now: number): boolean {
  if (!Number.isFinite(deletedAt)) {
    return false;
  }
  return deletedAt <= now + MAX_FUTURE_TOMBSTONE_SKEW_MS;
}
