/**
 * Process-wide application state.
 *
 * The database and the sync service are expensive to build and must be shared:
 * two `RdbStore` handles on the same file would contend for the same lock, and two
 * `SyncService` instances could start overlapping passes — the one failure mode
 * this protocol cannot recover from, because the server has no locking.
 *
 * Initialization is driven from `EntryAbility.onCreate` and is idempotent, so a
 * page that arrives before initialization finishes awaits the same promise rather
 * than racing it.
 */

import type { common } from '@kit.AbilityKit';
import {
  BookGroups,
  BookImporter,
  Bookmarks,
  Books,
  Database,
  FileStorage,
  hashFileSha256,
  Highlights,
  Notes,
  ReaderStore,
  SyncService,
} from 'data';
import type { BookGroup, Bookmark, Note } from 'data';
import { encodeSpineLocator, generateId } from 'core';

let initPromise: Promise<void> | undefined = undefined;
let database: Database | undefined = undefined;
let syncService: SyncService | undefined = undefined;
let books: Books | undefined = undefined;
let bookmarkRepo: Bookmarks | undefined = undefined;
let groupRepo: BookGroups | undefined = undefined;
let highlightRepo: Highlights | undefined = undefined;
let noteRepo: Notes | undefined = undefined;
let importer: BookImporter | undefined = undefined;
let readerStore: ReaderStore | undefined = undefined;
let storage: FileStorage | undefined = undefined;
let appContext: common.UIAbilityContext | undefined = undefined;
let initError: string = '';

/** Build the database and the sync service. Safe to call more than once. */
export function initAppCore(context: common.UIAbilityContext): Promise<void> {
  if (initPromise !== undefined) {
    return initPromise;
  }
  appContext = context;
  initPromise = (async (): Promise<void> => {
    try {
      const db: Database = await Database.open(context);
      const repository: Books = new Books(db);
      // A book left in `downloading` means the process died mid-transfer; without
      // this the row would show a permanent spinner.
      await repository.resetInterruptedDownloads();
      // One storage instance is handed to both the importer and the sync service,
      // so a file written by one is visible to the other.
      const storageInstance: FileStorage = FileStorage.fromContext(context, hashFileSha256);

      database = db;
      books = repository;
      bookmarkRepo = new Bookmarks(db);
      groupRepo = new BookGroups(db);
      highlightRepo = new Highlights(db);
      noteRepo = new Notes(db);
      storage = storageInstance;
      readerStore = new ReaderStore(db);
      importer = new BookImporter(context, storageInstance, repository);
      syncService = await SyncService.create(context, db);
    } catch (err) {
      initError = err instanceof Error ? err.message : JSON.stringify(err);
      // Re-wrapped rather than rethrown: ArkTS rejects `throw err` from a catch
      // clause (`arkts-limited-throw`). The page shows `appCoreError()`, so the
      // message is what matters, not the original class.
      throw new Error(initError);
    }
  })();
  return initPromise;
}

/** True when initialization has completed successfully. */
export function isAppCoreReady(): boolean {
  return database !== undefined && syncService !== undefined;
}

/** Human-readable initialization failure, or an empty string. */
export function appCoreError(): string {
  return initError;
}

/** The shared database. Throws when called before initialization finishes. */
export function db(): Database {
  if (database === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return database;
}

/** The shared sync service. Throws when called before initialization finishes. */
export function sync(): SyncService {
  if (syncService === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return syncService;
}

/** The shared book repository. */
export function bookRepository(): Books {
  if (books === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return books;
}

/** The shared importer. */
export function bookImporter(): BookImporter {
  if (importer === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return importer;
}

/** The ability context, for APIs that need one (picker, preferences, asset). */
export function abilityContext(): common.UIAbilityContext {
  if (appContext === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return appContext;
}

/**
 * Turn a sandbox-relative path into a `file://` URI for ArkUI.
 *
 * Exposed from here so the UI never needs the storage instance, and the sandbox
 * root stays in one place.
 */
export function toFileUri(relativePath: string): string {
  if (relativePath.length === 0 || storage === undefined) {
    return '';
  }
  return storage.toFileUri(`${storage.root()}/${relativePath}`);
}

/**
 * Absolute sandbox path for a book-relative path.
 *
 * Reader Kit opens a file by absolute path, not a URI, so this is the counterpart
 * to `toFileUri`.
 */
export function toAbsolutePath(relativePath: string): string {
  if (relativePath.length === 0 || storage === undefined) {
    return '';
  }
  if (relativePath.startsWith('/')) {
    return relativePath;
  }
  return `${storage.root()}/${relativePath}`;
}

/**
 * The shared reader state store.
 */
export function reader(): ReaderStore {
  if (readerStore === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return readerStore;
}

/**
 * Delete one local file, given the sandbox-relative path a row records.
 *
 * **Only ever called after the database write that decided to remove the file has
 * succeeded.** The reverse order — unlink first, write second — loses the book
 * outright if the process dies in between: no row to retry from, no file to read.
 * The call site in `Index.ets` (`deleteBookFromShelf`) is written in that order and
 * is the only caller.
 *
 * An absent file is success, not an error (`FileStorage.remove`): a book that was
 * never downloaded has a `file_path` naming a file this device does not have, and
 * "already gone" is the goal state here. An empty path is a no-op.
 *
 * This is a **local** unlink. Nothing in this function, or in its caller, can reach
 * the server: there is no WebDAV client in either path, and this app never deletes a
 * remote file.
 */
export async function removeLocalFile(relativePath: string): Promise<void> {
  if (relativePath.length === 0 || storage === undefined) {
    return;
  }
  await storage.remove(toAbsolutePath(relativePath));
}

/**
 * A summary of the database's effective configuration.
 *
 * Surfaced in the self-test block so the answers are observable on a device rather
 * than assumed. `PRAGMA foreign_keys = ON` is what makes every cascade delete work,
 * and SQLite disables foreign keys by default — a store that silently refused the
 * pragma would delete a book without its annotations and look like a data bug.
 */
export function databaseDiagnostics(): string {
  if (database === undefined) {
    return '数据库未打开';
  }
  return database.rdbHandle.diagnostics();
}

/** The shared shelf-group repository. */
export function groupStore(): BookGroups {
  if (groupRepo === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return groupRepo;
}

/**
 * How many shelf groups exist.
 *
 * Used by the self-test block: the group table is created by DDL on a fresh install,
 * and a count is the cheapest proof that the table exists and is queryable. It also
 * makes the profile sync visible — a group created on another device appears here.
 */
export async function groupCount(): Promise<number> {
  if (groupRepo === undefined) {
    return -1;
  }
  try {
    const groups: BookGroup[] = await groupRepo.listAll();
    return groups.length;
  } catch (err) {
    return -1;
  }
}

/** The shared bookmark repository. */
export function bookmarkStore(): Bookmarks {
  if (bookmarkRepo === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return bookmarkRepo;
}

/** The shared highlight repository. */
export function highlightStore(): Highlights {
  if (highlightRepo === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return highlightRepo;
}

/** The shared note repository. */
export function noteStore(): Notes {
  if (noteRepo === undefined) {
    throw new Error('AppCore 尚未初始化完成');
  }
  return noteRepo;
}

/**
 * Create a bookmark at the reader's current position.
 *
 * The locator is this client's `spine:{n}:{domPos}` form, not a CFI — see
 * `core/reader/Locator.ets` for why, and for what that costs on interoperability.
 *
 * A bookmark at page granularity rather than a text range is a platform limit, not
 * a design choice: Reader Kit exposes no selection API, so there is no character
 * range to record. The label the user types is what makes the bookmark findable
 * later.
 */
export async function createBookmarkAt(
  bookId: string,
  spineIndex: number,
  domPos: string,
  label: string,
  chapterTitle: string,
): Promise<Bookmark> {
  const store: Bookmarks = bookmarkStore();
  const now: number = Date.now();
  const locator: string = encodeSpineLocator(spineIndex, domPos);
  const bookmark: Bookmark = {
    id: generateId(),
    bookId: bookId,
    cfi: locator,
    label: label,
    chapterTitle: chapterTitle,
    createdAt: now,
    updatedAt: now,
  };
  await store.insert(bookmark);
  return bookmark;
}

/**
 * Create a note anchored to the reader's current page.
 *
 * The quote is captured from the page's own reported text range rather than a user
 * selection, for the same reason as above.
 */
export async function createNoteAt(
  bookId: string,
  spineIndex: number,
  domPos: string,
  title: string,
  content: string,
  chapterTitle: string,
): Promise<Note> {
  const store: Notes = noteStore();
  const now: number = Date.now();
  const note: Note = {
    id: generateId(),
    bookId: bookId,
    highlightId: '',
    cfi: encodeSpineLocator(spineIndex, domPos),
    title: title,
    content: content,
    chapterTitle: chapterTitle,
    tags: [],
    createdAt: now,
    updatedAt: now,
  };
  await store.insert(note);
  return note;
}
