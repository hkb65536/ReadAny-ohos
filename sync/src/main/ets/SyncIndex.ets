/**
 * Remote index and per-book file models.
 *
 * Ported from ReadAny `packages/core/src/sync/per-book-sync.ts`. The index lives
 * at `/readany/sync/index.json` and is the membership list plus a change marker
 * per book. It is merged field-by-field (never overwritten wholesale) because
 * there is no locking on the server: the only concurrency protection in this
 * protocol is "re-read the remote index, merge, write back".
 */

import { INDEX_SCHEMA_VERSION } from './SyncConstants';

/**
 * Per-book index entry. A missing field means "no information", so every field
 * is a sentinel-backed number rather than an optional.
 */
export interface BookIndexEntry {
  /** `books.updated_at` marker. */
  b: number;
  /** Max annotations `updated_at` for this book. */
  a: number;
  /** Tombstone: `books` row deleted at. */
  d: number;
}

/** Per-thread index entry. */
export interface ThreadIndexEntry {
  /** `threads.updated_at` marker. */
  t: number;
  /** Tombstone: thread deleted at. */
  d: number;
}

/** Sentinel for "this marker was never recorded". */
export const NO_MARKER: number = 0;

export function emptyBookEntry(): BookIndexEntry {
  return { b: NO_MARKER, a: NO_MARKER, d: NO_MARKER };
}

export function emptyThreadEntry(): ThreadIndexEntry {
  return { t: NO_MARKER, d: NO_MARKER };
}

export function bookEntry(b: number, a: number, d: number): BookIndexEntry {
  return { b: b, a: a, d: d };
}

export function threadEntry(t: number, d: number): ThreadIndexEntry {
  return { t: t, d: d };
}

/** Remote `/readany/sync/index.json`. */
export interface SyncIndexFile {
  schemaVersion: number;
  updatedAt: number;
  books: Map<string, BookIndexEntry>;
  threads: Map<string, ThreadIndexEntry>;
}

export function emptyIndex(): SyncIndexFile {
  return {
    schemaVersion: INDEX_SCHEMA_VERSION,
    updatedAt: 0,
    books: new Map<string, BookIndexEntry>(),
    threads: new Map<string, ThreadIndexEntry>(),
  };
}

/**
 * Per-field max union of two book entries.
 *
 * Built field by field rather than by spreading and then taking maxima: with a
 * "start from the spread, then max the fields where *both* sides are present"
 * approach, a side that carries only some markers would have its present markers
 * overwritten by the zero-filled defaults of the other side — silently dropping
 * a peer's change marker and making this client re-pull or, worse, ignore it.
 * Taking the max against the sentinel for absent fields gives the same result as
 * the reference implementation's "only max when both are present".
 */
export function mergeBookEntry(
  remote: BookIndexEntry | undefined,
  ours: BookIndexEntry | undefined,
): BookIndexEntry {
  if (remote === undefined && ours === undefined) {
    return emptyBookEntry();
  }
  return {
    b: Math.max(remote?.b ?? NO_MARKER, ours?.b ?? NO_MARKER),
    a: Math.max(remote?.a ?? NO_MARKER, ours?.a ?? NO_MARKER),
    d: Math.max(remote?.d ?? NO_MARKER, ours?.d ?? NO_MARKER),
  };
}

/** Per-field max union of two thread entries. Same reasoning as `mergeBookEntry`. */
export function mergeThreadEntry(
  remote: ThreadIndexEntry | undefined,
  ours: ThreadIndexEntry | undefined,
): ThreadIndexEntry {
  if (remote === undefined && ours === undefined) {
    return emptyThreadEntry();
  }
  return {
    t: Math.max(remote?.t ?? NO_MARKER, ours?.t ?? NO_MARKER),
    d: Math.max(remote?.d ?? NO_MARKER, ours?.d ?? NO_MARKER),
  };
}

/** Per-id max union of two `id -> deletedAt` maps. */
export function mergeDeletedMap(
  remote: Map<string, number> | undefined,
  ours: Map<string, number> | undefined,
): Map<string, number> | undefined {
  if (remote === undefined && ours === undefined) {
    return undefined;
  }
  const merged: Map<string, number> = new Map<string, number>();
  if (remote !== undefined) {
    remote.forEach((value: number, key: string): void => {
      merged.set(key, value);
    });
  }
  if (ours !== undefined) {
    ours.forEach((value: number, key: string): void => {
      const existing: number | undefined = merged.get(key);
      merged.set(key, Math.max(existing ?? 0, value));
    });
  }
  return merged;
}

/**
 * Merge our index into the remote one. Every marker takes the maximum, so a
 * peer's change is never dropped even when this device has older information
 * for the same book.
 */
export function mergeIndex(remote: SyncIndexFile | undefined, ours: SyncIndexFile): SyncIndexFile {
  if (remote === undefined) {
    return ours;
  }

  const books: Map<string, BookIndexEntry> = new Map<string, BookIndexEntry>();
  remote.books.forEach((entry: BookIndexEntry, id: string): void => {
    books.set(id, entry);
  });
  ours.books.forEach((entry: BookIndexEntry, id: string): void => {
    books.set(id, mergeBookEntry(remote.books.get(id), entry));
  });

  const threads: Map<string, ThreadIndexEntry> = new Map<string, ThreadIndexEntry>();
  remote.threads.forEach((entry: ThreadIndexEntry, id: string): void => {
    threads.set(id, entry);
  });
  ours.threads.forEach((entry: ThreadIndexEntry, id: string): void => {
    threads.set(id, mergeThreadEntry(remote.threads.get(id), entry));
  });

  return {
    schemaVersion: INDEX_SCHEMA_VERSION,
    updatedAt: Math.max(remote.updatedAt, ours.updatedAt),
    books: books,
    threads: threads,
  };
}

/** True when our entry already covers everything the remote entry claims. */
export function isBookEntryCovered(ours: BookIndexEntry | undefined, remote: BookIndexEntry | undefined): boolean {
  if (remote === undefined) {
    return true;
  }
  if (ours === undefined) {
    return false;
  }
  return ours.b >= remote.b && ours.a >= remote.a && ours.d >= remote.d;
}

/** True when the remote book is deleted and no local edit supersedes it. */
export function isRemoteBookDeleted(
  entry: BookIndexEntry | undefined,
  localB: number,
  localA: number,
): boolean {
  if (entry === undefined || entry.d <= NO_MARKER) {
    return false;
  }
  return entry.d >= Math.max(localB, localA);
}
