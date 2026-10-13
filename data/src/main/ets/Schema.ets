/**
 * Local database schema.
 *
 * Ported from ReadAny `packages/core/src/db/db-core.ts`.
 *
 * IMPORTANT — why this is one consolidated script rather than the original's
 * `CREATE TABLE` plus a stream of `ALTER TABLE ADD COLUMN` statements:
 *
 * In ReadAny the initial `CREATE TABLE` reflects a historical first version, and
 * every column added since arrives through an `ALTER TABLE ... ADD COLUMN` that
 * swallows the "duplicate column" error. New installs walk the same path, so a
 * fresh database only ends up complete because the ALTER chain runs.
 *
 * Recreating that pattern here would be actively harmful. The sync engine writes
 * remote rows through a "insert ... on conflict do update set <every column>"
 * statement built from the columns actually present in the table. If this client
 * created a narrower table than the server-side peers expect, that upsert would
 * silently drop the columns this client is missing — no error, just lost data
 * for the other devices. So every column is declared up front, exactly once, and
 * `SCHEMA_MIGRATIONS` exists for future changes rather than for back-filling the
 * past.
 *
 * Column order follows the original's final order (CREATE order, then ALTER
 * order), which keeps `SELECT *` results comparable when debugging against a
 * ReadAny database.
 */

/**
 * Tables whose rows participate in sync. Kept as a constant so the sync engine
 * and the repositories agree on the set.
 *
 * ReadAny also syncs `tags`, `book_tags`, `book_groups`, `threads`, `messages`
 * and `skills`. Those belong to features outside this client's scope (tag
 * management, AI chat, reading statistics), so they are not created here. The
 * consequence is deliberate and worth stating: if a peer's `index.json` lists a
 * book whose only local trace would have been a tag row, this client still pulls
 * the book itself — tags are not part of a book's sync file.
 */
export const SYNC_TABLES: string[] = ['books', 'highlights', 'notes', 'bookmarks'];
/** Tables holding the user's annotations, grouped per book in the sync file. */
export const ANNOTATION_TABLES: string[] = ['highlights', 'notes', 'bookmarks'];

/**
 * Full DDL, in dependency order (parents before children because of the foreign
 * keys).
 */
export const SCHEMA_STATEMENTS: string[] = [
  // -------------------------------------------------------------------------
  // books
  // -------------------------------------------------------------------------
  `CREATE TABLE IF NOT EXISTS books (
    id TEXT PRIMARY KEY,
    file_path TEXT NOT NULL,
    format TEXT NOT NULL DEFAULT 'epub',
    title TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    publisher TEXT,
    language TEXT,
    isbn TEXT,
    description TEXT,
    cover_url TEXT,
    publish_date TEXT,
    rating REAL,
    reviews TEXT,
    subjects TEXT,
    total_pages INTEGER DEFAULT 0,
    total_chapters INTEGER DEFAULT 0,
    group_id TEXT,
    added_at INTEGER NOT NULL,
    last_opened_at INTEGER,
    deleted_at INTEGER,
    progress REAL DEFAULT 0,
    current_cfi TEXT,
    current_spine INTEGER DEFAULT 0,
    current_dom_pos TEXT,
    is_vectorized INTEGER DEFAULT 0,
    vectorize_progress REAL DEFAULT 0,
    tags TEXT DEFAULT '[]',
    updated_at INTEGER NOT NULL DEFAULT 0,
    file_hash TEXT,
    sync_status TEXT NOT NULL DEFAULT 'local',
    sync_version INTEGER DEFAULT 0,
    last_modified_by TEXT
  )`,

  // -------------------------------------------------------------------------
  // annotations
  // -------------------------------------------------------------------------
  `CREATE TABLE IF NOT EXISTS highlights (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    cfi TEXT NOT NULL,
    text TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'yellow',
    note TEXT,
    chapter_title TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_version INTEGER DEFAULT 0,
    last_modified_by TEXT,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
  )`,

  `CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    highlight_id TEXT,
    cfi TEXT,
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    chapter_title TEXT,
    tags TEXT DEFAULT '[]',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_version INTEGER DEFAULT 0,
    last_modified_by TEXT,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
  )`,

  // `updated_at` is not in the original CREATE — it arrives via migration 8, and
  // that migration also back-fills it from `created_at`. Declaring it here with
  // the same NOT NULL DEFAULT 0 keeps the sync timestamp column non-null for
  // rows written before any back-fill would have run.
  `CREATE TABLE IF NOT EXISTS bookmarks (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    cfi TEXT NOT NULL,
    label TEXT,
    chapter_title TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER DEFAULT 0,
    last_modified_by TEXT,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
  )`,

  // -------------------------------------------------------------------------
  // profile: book groups
  //
  // Column layout copied from the reference schema, including `sort_order` and
  // `created_at`, because these rows travel to peers as-is: a column missing here
  // would be dropped the next time this client uploads the profile file.
  //
  // `group_id` on `books` is only a reference. The group's own name and ordering live
  // here, which is why a client without this table shows no groups at all.
  // -------------------------------------------------------------------------
  `CREATE TABLE IF NOT EXISTS book_groups (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER DEFAULT 0,
    last_modified_by TEXT
  )`,

  `CREATE INDEX IF NOT EXISTS idx_books_group ON books(group_id)`,
  `CREATE INDEX IF NOT EXISTS idx_book_groups_updated ON book_groups(updated_at)`,

  // -------------------------------------------------------------------------
  // sync bookkeeping
  // -------------------------------------------------------------------------
  // Primary key is (id, table_name). `book_id` is an ordinary column (added by
  // the original's "migration 5b") that attributes a deletion to its book, which
  // is what lets a book's sync file carry the deletion of its own annotations.
  `CREATE TABLE IF NOT EXISTS sync_tombstones (
    id TEXT NOT NULL,
    table_name TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    book_id TEXT,
    PRIMARY KEY (id, table_name)
  )`,

  `CREATE TABLE IF NOT EXISTS sync_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`,

  // -------------------------------------------------------------------------
  // indexes
  // -------------------------------------------------------------------------
  'CREATE INDEX IF NOT EXISTS idx_highlights_book ON highlights(book_id)',
  'CREATE INDEX IF NOT EXISTS idx_notes_book ON notes(book_id)',
  'CREATE INDEX IF NOT EXISTS idx_bookmarks_book ON bookmarks(book_id)',
  'CREATE INDEX IF NOT EXISTS idx_tombstones_deleted_at ON sync_tombstones(deleted_at)',
  'CREATE INDEX IF NOT EXISTS idx_books_group ON books(group_id)',
  'CREATE INDEX IF NOT EXISTS idx_books_deleted_at ON books(deleted_at)',
  // Helps the per-book sync pull decide which books changed without a full scan.
  'CREATE INDEX IF NOT EXISTS idx_books_updated_at ON books(updated_at)',
];

/** A forward-only schema change. */
export interface SchemaMigration {
  version: number;
  description: string;
  statements: string[];
}

/**
 * Forward-only migrations.
 *
 * Empty on first release: version 1 is `SCHEMA_STATEMENTS` itself. Append here
 * for any future column or table, and never edit an existing entry — an installed
 * client has already run it.
 */
export const SCHEMA_MIGRATIONS: SchemaMigration[] = [];

/** Schema version this build expects. */
export const CURRENT_SCHEMA_VERSION: number = 1;

/** Book availability, mirroring ReadAny's `sync_status`. */
export const SYNC_STATUS_LOCAL: string = 'local';
export const SYNC_STATUS_REMOTE: string = 'remote';
export const SYNC_STATUS_DOWNLOADING: string = 'downloading';

/** `sync_metadata` keys used by this client. */
export const META_DEVICE_ID: string = 'device_id';
export const META_LAST_SYNC_AT: string = 'last_sync_at';
