/**
 * Local file storage for book files and covers.
 *
 * Layout inside the app sandbox, matching the canonical paths the reference
 * clients use so a synced row's `file_path`/`cover_url` mean the same thing here:
 *
 *     books/{bookId}.{ext}
 *     covers/{bookId}.{ext}
 *     covers/{bookId}-custom-{stamp}.{ext}   (user-supplied cover)
 *
 * `convertFileSrc` exists because ArkUI's `Image` cannot load a bare sandbox path;
 * it needs a `file://` URI. Getting that wrong shows as a blank cover rather than
 * an error, which is why it lives here next to the path builders instead of at the
 * call site.
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BOOKS_DIR, COVERS_DIR, InkBoatError, SyncErrorKind, TMP_DIR } from 'core';

/** What a stored file looks like on disk, or an absence. */
export interface LocalFileInfo {
  exists: boolean;
  size: number;
  path: string;
}

/** SHA-256 of a file, or an empty string when it could not be computed. */
export type FileHasher = (path: string) => Promise<string>;

function fail(action: string, err: Object): InkBoatError {
  const message: string = err instanceof Error ? err.message : JSON.stringify(err);
  return new InkBoatError(SyncErrorKind.FILE, `${action}：${message}`);
}

export class FileStorage {
  private readonly filesDir: string;
  /** Injected so the storage layer does not depend on the crypto stack. */
  private readonly hash: FileHasher;

  constructor(filesDir: string, hash: FileHasher) {
    this.filesDir = filesDir;
    this.hash = hash;
  }

  /**
   * Build for an ability context.
   *
   * `filesDir` is the app's private directory: it survives updates and is removed
   * on uninstall, which is exactly the lifetime book files should have. Caches
   * live elsewhere precisely because the system may delete them.
   */
  static fromContext(context: common.UIAbilityContext, hash: FileHasher): FileStorage {
    return new FileStorage(context.filesDir, hash);
  }

  /** The app's private files directory. */
  root(): string {
    return this.filesDir;
  }

  /** `books/{bookId}.{ext}` */
  bookPath(bookId: string, ext: string): string {
    return `${this.filesDir}/${BOOKS_DIR}/${bookId}.${normalizeExt(ext)}`;
  }

  /** `covers/{bookId}.{ext}` — the cover extracted from the book itself. */
  coverPath(bookId: string, ext: string): string {
    return `${this.filesDir}/${COVERS_DIR}/${bookId}.${normalizeExt(ext)}`;
  }

  /** Workspace for partial transfers, so an interrupted download never looks complete. */
  tempPath(name: string): string {
    return `${this.filesDir}/${TMP_DIR}/${name}`;
  }

  /** Create the directory tree this storage needs. */
  async ensureLayout(): Promise<void> {
    for (const dir of [BOOKS_DIR, COVERS_DIR, TMP_DIR]) {
      await this.ensureDir(`${this.filesDir}/${dir}`);
    }
  }

  /**
   * Create a directory, including missing parents.
   *
   * `recursion: true` makes this idempotent, which matters because the layout is
   * ensured on every sync rather than tracked with a flag.
   */
  async ensureDir(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
    } catch (err) {
      // Creating an existing directory is not an error for our purposes.
      if (!await this.exists(path)) {
        throw fail(`创建目录 ${path} 失败`, err as Object);
      }
    }
  }

  /**
   * Create the parent directory of a file path, including missing parents.
   *
   * `fileIo.open` with `CREATE` creates the *file*, not the directories above it, so the
   * first write into `books/`, `covers/` or `tmp/` on a device that has never written
   * there fails with ENOENT. `ensureLayout` creates those three directories, but it is
   * called by the v2 engine and by the importer — not by the transfer executor, which is
   * the only place that knows the destination it is about to open. This derives the
   * directory from the path being written, so the guarantee sits with the write instead of
   * depending on a caller having run first, and it covers a destination outside the three
   * directories this class names.
   *
   * `ensureDir` is idempotent, so calling this before every transfer is safe. The cost on a
   * directory that already exists is one `mkdir` attempt, plus one `access` only when that
   * attempt reports an error.
   */
  async ensureParentOf(path: string): Promise<void> {
    const cut: number = path.lastIndexOf('/');
    if (cut <= 0) {
      // No parent to create: an empty string, or a path directly under the root. The
      // root itself always exists — it is the app's own `filesDir`.
      return;
    }
    await this.ensureDir(path.substring(0, cut));
  }

  /** Existence check that never throws. */
  async exists(path: string): Promise<boolean> {
    try {
      return await fileIo.access(path);
    } catch (err) {
      return false;
    }
  }

  /** Size and existence in one call, since callers almost always want both. */
  async info(path: string): Promise<LocalFileInfo> {
    try {
      const stat: fileIo.Stat = await fileIo.stat(path);
      return { exists: true, size: stat.size, path: path };
    } catch (err) {
      return { exists: false, size: 0, path: path };
    }
  }

  /** Read a whole file into memory. */
  async readBytes(path: string): Promise<Uint8Array> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(path);
      if (stat.size === 0) {
        return new Uint8Array(0);
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = await fileIo.read(file.fd, buffer);
      const bytes: Uint8Array = new Uint8Array(buffer);
      // A short read yields trailing zeros, which would corrupt a JSON parse or a
      // hash. Truncating to the reported length is the correct recovery.
      return read === stat.size ? bytes : bytes.slice(0, read);
    } catch (err) {
      throw fail(`读取文件 ${path} 失败`, err as Object);
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch (closeErr) {
          // A failed close must not mask the original error.
        }
      }
    }
  }

  /**
   * Write bytes, replacing any existing file.
   *
   * TRUNC is essential: without it a shorter rewrite would leave the tail of the
   * previous, longer file in place.
   */
  async writeBytes(path: string, data: Uint8Array): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(
        path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );
      if (data.byteLength > 0) {
        await fileIo.write(file.fd, data.buffer as ArrayBuffer);
      }
    } catch (err) {
      throw fail(`写入文件 ${path} 失败`, err as Object);
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch (closeErr) {
          // Ignored; see readBytes.
        }
      }
    }
  }

  /** Write text as UTF-8. */
  async writeText(path: string, text: string): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(
        path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );
      await fileIo.write(file.fd, text);
    } catch (err) {
      throw fail(`写入文件 ${path} 失败`, err as Object);
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch (closeErr) {
          // Ignored.
        }
      }
    }
  }

  /** Copy a file, overwriting the destination. */
  async copy(src: string, dest: string): Promise<void> {
    try {
      await fileIo.copyFile(src, dest);
    } catch (err) {
      throw fail(`复制 ${src} -> ${dest} 失败`, err as Object);
    }
  }

  /**
   * Delete a file. Absent is success.
   *
   * Callers delete as cleanup, where "already gone" is the goal state rather than
   * a failure worth reporting.
   */
  async remove(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (err) {
      if (await this.exists(path)) {
        throw fail(`删除 ${path} 失败`, err as Object);
      }
    }
  }

  /** Rename/move within the sandbox, used to promote a temp download. */
  async move(src: string, dest: string): Promise<void> {
    try {
      await fileIo.copyFile(src, dest);
      await this.remove(src);
    } catch (err) {
      throw fail(`移动 ${src} -> ${dest} 失败`, err as Object);
    }
  }

  /** SHA-256 of a file, or an empty string when unavailable. */
  async hashOf(path: string): Promise<string> {
    try {
      return await this.hash(path);
    } catch (err) {
      return '';
    }
  }

  /**
   * A `file://` URI for a sandbox path.
   *
   * ArkUI's `Image` needs this form; a bare path renders as nothing rather than
   * raising, so the conversion is centralised here.
   */
  toFileUri(path: string): string {
    if (path.startsWith('file://')) {
      return path;
    }
    if (path.startsWith('/')) {
      return `file://${path}`;
    }
    return `file:///${path}`;
  }
}

/** Strip a leading dot so `bookPath(id, '.epub')` and `bookPath(id, 'epub')` agree. */
function normalizeExt(ext: string): string {
  return ext.startsWith('.') ? ext.substring(1) : ext;
}
