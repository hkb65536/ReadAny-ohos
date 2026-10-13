/**
 * Book import.
 *
 * Flow: pick a file, copy it into the sandbox, extract or convert it, read the package
 * document, then persist the book row and its cover.
 *
 * Three platform constraints shaped this, each verified against the SDK rather
 * than assumed:
 *
 *  1. `zlib.decompressFile` requires its **input file name to end in `.zip`**.
 *     An `.epub` is a ZIP in every way except the name, so the copy made into the
 *     sandbox is stored with a `.zip` extension purely to satisfy that check.
 *  2. It also accepts only application sandbox paths, so the picker's document URI
 *     has to be copied in first — it cannot be extracted from where it lives.
 *  3. There is no entry-level ZIP reader, so the whole archive is extracted to a
 *     temporary directory and read back by path. The temporary directory is
 *     removed afterwards regardless of outcome.
 *
 * ## What is accepted, and what is refused
 *
 * The reader is Reader Kit, which is an **EPUB engine**: `bookParser.getDefaultHandler`
 * (`ReaderView.ets:433`) is handed a path and parses it as an EPUB. Nothing else can be
 * opened, so nothing else may be stored as if it could.
 *
 *  - **EPUB** is parsed as before.
 *  - **TXT** is converted to EPUB here (`TxtToEpub`), which is what ReadAny does for
 *    `txt` and `umd` (`packages/app/src/stores/library-store.ts:421`, `:444`).
 *  - **Everything else is refused**, by name and before a single byte is written. This
 *    used to be the defect: `pdf`, `mobi`, `azw3`, `fb2` and `cbz` were in the accepted
 *    list, copied verbatim, and then failed to open with a bare "无法解析这本书" and no
 *    explanation of why — or, worse, of the fact that they never could open.
 *
 * `format` on the stored row is the **source** format, matching ReadAny. The file on disk
 * is `books/{id}.epub` for both accepted kinds, and the path is built by
 * `bookFilePathForExtension` rather than from `format`, so no path can point at a
 * `.txt` that does not exist. See `V1BookPaths.resolveBookExtension`.
 */

import { fileIo, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { generateId, InkBoatError, SyncErrorKind } from 'core';
import type { Book, BookFormat } from './Types';
import { Books } from './Books';
import { FileStorage } from './FileStorage';
import type { EpubMetadata, EpubSource } from './EpubMetadata';
import { emptyEpubMetadata, extensionOf, parseEpub } from './EpubMetadata';
import { bookFilePathForExtension } from './V1BookPaths';
import { TxtToEpubConverter } from './TxtToEpub';
import type { TxtConvertResult } from './TxtToEpub';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatImport';

/** Outcome of one import attempt. */
export interface ImportResult {
  /** The book that was added, or `undefined` when the user cancelled. */
  book: Book | undefined;
  /** True when the user dismissed the picker. */
  cancelled: boolean;
  /** Non-fatal notes, such as a missing cover or unreadable title. */
  warnings: string[];
}

function fail(action: string, err: Object): InkBoatError {
  const message: string = err instanceof Error ? err.message : JSON.stringify(err);
  return new InkBoatError(SyncErrorKind.FILE, `${action}：${message}`);
}

/**
 * Formats the picker offers, and the only ones this client can turn into a book it can
 * open. Narrowed deliberately: offering a PDF it would then refuse is worse than not
 * offering it, and the refusal path below still catches one that arrives another way.
 */
const PICKER_SUFFIXES: string[] = ['.epub', '.txt'];

/** Formats this client can open directly (EPUB) or convert to EPUB (TXT). */
const READABLE_FORMATS: string[] = ['epub', 'txt'];

/**
 * Formats ReadAny supports that this client cannot read, with the reason.
 *
 * Named rather than folded into one "unsupported" message because the user's next
 * question is always "but the desktop client opened it", and the answer is different per
 * format: there is no PDF renderer or MOBI decoder here at all.
 */
const UNREADABLE_FORMATS: string[] = ['pdf', 'mobi', 'azw', 'azw3', 'cbz', 'cbr', 'fb2', 'fbz', 'umd'];

/** The extension a stored book file has for every accepted source format. */
const STORED_BOOK_EXTENSION: string = 'epub';

export class BookImporter {
  private readonly context: common.UIAbilityContext;
  private readonly storage: FileStorage;
  private readonly books: Books;

  constructor(
    context: common.UIAbilityContext,
    storage: FileStorage,
    books: Books,
  ) {
    this.context = context;
    this.storage = storage;
    this.books = books;
  }

  /**
   * Let the user choose files and import each one.
   *
   * Multiple selection is allowed because building a library one file at a time is
   * tedious; each file is imported independently so one bad EPUB does not lose the
   * rest of the selection.
   */
  async pickAndImport(): Promise<ImportResult> {
    let uris: string[] = [];
    try {
      const selectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 20;
      selectOptions.fileSuffixFilters = PICKER_SUFFIXES;
      // The context-taking constructor is the recommended one; the no-argument
      // form is documented as failing intermittently.
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
      uris = await documentPicker.select(selectOptions);
    } catch (err) {
      // A dismissed picker is reported as an error by some system versions, so it
      // is treated as a cancellation rather than surfaced as a failure.
      return { book: undefined, cancelled: true, warnings: [] };
    }

    if (uris.length === 0) {
      return { book: undefined, cancelled: true, warnings: [] };
    }

    await this.storage.ensureLayout();

    let firstBook: Book | undefined = undefined;
    const warnings: string[] = [];
    for (const uri of uris) {
      try {
        const book: Book = await this.importOne(uri, warnings);
        if (firstBook === undefined) {
          firstBook = book;
        }
      } catch (err) {
        const message: string = err instanceof InkBoatError
          ? err.message
          : (err instanceof Error ? err.message : JSON.stringify(err));
        warnings.push(message);
      }
    }
    return { book: firstBook, cancelled: false, warnings: warnings };
  }

  /**
   * Import one document URI.
   *
   * The book row is written before the cover is extracted: a book with metadata
   * and no cover is usable, whereas failing after a successful parse because the
   * cover was unreadable would lose a good import for a cosmetic reason.
   *
   * Nothing is written until the format has been accepted, and the file is promoted to
   * its final path only after it is whole, so a refused or failed import leaves no book
   * on disk and no row in the database.
   */
  async importOne(uri: string, warnings: string[]): Promise<Book> {
    const bookId: string = generateId();
    const sourceName: string = fileNameFromUri(uri);
    const format: string = formatFromName(sourceName);

    this.refuseUnreadable(format, sourceName);

    // Both accepted formats end up as an EPUB on disk; only the source format recorded
    // on the row differs. `bookFilePathForExtension` is the one place that composes
    // `books/{id}.{ext}`, and it takes the extension rather than the format so this
    // cannot be written as `.txt`.
    const storedRelativePath: string = bookFilePathForExtension(bookId, STORED_BOOK_EXTENSION);
    const bookPath: string = `${this.storage.root()}/${storedRelativePath}`;
    await this.storage.ensureParentOf(bookPath);

    let metadata: EpubMetadata = emptyEpubMetadata();
    let coverTmpPath: string = '';
    let totalChapters: number = 0;

    if (format === 'epub') {
      // Parsed once, inside the extraction step, and returned: parsing again here
      // would re-read the whole package document for no new information.
      const bundle = await this.copyAndExtract(uri, bookId, warnings);
      metadata = bundle.metadata;
      coverTmpPath = bundle.coverTmpPath;
      totalChapters = metadata.chapterCount;
      // The extracted copy is the one worth keeping: it has a `.zip` name, so it
      // cannot serve as the book file. The original was copied alongside it.
      if (bundle.sandboxCopy.length > 0) {
        await this.storage.move(bundle.sandboxCopy, bookPath);
      }
    } else {
      const converted: TxtConversion = await this.convertTxt(uri, bookId, bookPath, warnings);
      metadata = converted.metadata;
      totalChapters = converted.chapterCount;
    }

    const title: string = metadata.title.length > 0 ? metadata.title : stripExtension(sourceName);
    const now: number = Date.now();

    // A cover is stored next to the book as `covers/{id}.{ext}` so the sync layer's
    // canonical-cover rule recognises it rather than treating it as a custom one.
    let coverUrl: string = '';
    if (coverTmpPath.length > 0) {
      const coverExt: string = metadata.coverExt.length > 0 ? metadata.coverExt : 'jpg';
      const coverPath: string = this.storage.coverPath(bookId, coverExt);
      try {
        await this.storage.move(coverTmpPath, coverPath);
        coverUrl = `${coverRelDir()}/${bookId}.${coverExt}`;
      } catch (err) {
        warnings.push('封面写入失败，已跳过');
      }
    }

    const book: Book = {
      id: bookId,
      filePath: storedRelativePath,
      // The **source** format, which is what ReadAny records
      // (`packages/app/src/stores/library-store.ts:394-407`) while storing the converted
      // EPUB. It is metadata about where the book came from, not a claim about the file's
      // extension — `resolveBookExtension` exists so nothing derives a path from it.
      format: format as BookFormat,
      title: title,
      author: metadata.author,
      publisher: metadata.publisher,
      language: metadata.language,
      isbn: '',
      description: metadata.description,
      coverUrl: coverUrl,
      publishDate: '',
      rating: 0,
      reviews: '',
      subjects: '',
      totalPages: 0,
      totalChapters: totalChapters,
      groupId: '',
      addedAt: now,
      lastOpenedAt: 0,
      updatedAt: now,
      deletedAt: 0,
      progress: 0,
      currentCfi: '',
      currentSpine: 0,
      currentDomPos: '',
      tags: [],
      fileHash: '',
      syncStatus: 'local',
    };

    await this.books.upsert(book);
    return book;
  }

  /**
   * Refuse a format this client cannot read, naming it and saying why.
   *
   * Reader Kit is an EPUB engine, so "cannot read" is everything but EPUB and TXT, and
   * the failure it used to produce was a stored book that would not open and a generic
   * parser error. Refusing here means the user is told at the moment of import, while
   * they still remember which file they picked.
   */
  private refuseUnreadable(format: string, sourceName: string): void {
    if (READABLE_FORMATS.includes(format)) {
      return;
    }
    if (UNREADABLE_FORMATS.includes(format)) {
      throw new InkBoatError(
        SyncErrorKind.UNSUPPORTED,
        `暂不支持导入 ${format.toUpperCase()} 文件（${sourceName}）：`
        + '本应用的阅读器只支持 EPUB，导入时会转换 TXT，其它格式在桌面端是原样保存的，'
        + '这里既无法打开也无法转换。',
      );
    }
    throw new InkBoatError(
      SyncErrorKind.UNSUPPORTED,
      `不支持的格式：${sourceName}（仅支持 EPUB 与 TXT）`,
    );
  }

  /**
   * Convert a picked TXT into the book file.
   *
   * Three steps, in this order and for this reason: the picker's URI is copied into the
   * sandbox because the converter reads by path; the EPUB is written to a temporary path
   * so a failed conversion cannot leave a half-written book at the real one; and only
   * then is it promoted. The temporary TXT is removed either way.
   */
  private async convertTxt(
    uri: string,
    bookId: string,
    bookPath: string,
    warnings: string[],
  ): Promise<TxtConversion> {
    const sourceTmp: string = this.storage.tempPath(`import-${bookId}.txt`);
    const epubTmp: string = this.storage.tempPath(`import-${bookId}.epub`);
    await this.storage.ensureParentOf(sourceTmp);

    try {
      await this.copyInto(uri, sourceTmp);
    } catch (err) {
      throw fail('复制 TXT 文件失败', err as Object);
    }

    let converted: TxtConvertResult;
    try {
      const converter: TxtToEpubConverter = new TxtToEpubConverter();
      converted = await converter.convert({
        sourcePath: sourceTmp,
        destPath: epubTmp,
        identifier: bookId,
        author: '',
        language: '',
      });
    } catch (err) {
      await this.removeQuietly(sourceTmp);
      await this.removeQuietly(epubTmp);
      throw fail('TXT 转换为 EPUB 失败', err as Object);
    }

    try {
      await this.storage.move(epubTmp, bookPath);
    } catch (err) {
      await this.removeQuietly(sourceTmp);
      throw fail('写入转换后的 EPUB 失败', err as Object);
    }
    await this.removeQuietly(sourceTmp);

    warnings.push(
      `TXT 已转换为 EPUB：编码 ${converted.encoding}，共 ${converted.chapterCount} 章`,
    );
    if (converted.usedParagraphFallback) {
      // Not a failure: the book reads correctly. But the table of contents is 1..n and
      // says nothing about the text, which the user will notice, so it is said here
      // rather than left to be discovered.
      warnings.push('未识别到章节标题，已按段落自动分章（目录为序号）');
    }

    const metadata: EpubMetadata = emptyEpubMetadata();
    metadata.title = converted.bookTitle;
    metadata.author = converted.author;
    metadata.language = converted.language;
    metadata.chapterCount = converted.chapterCount;
    metadata.version = '2.0';
    const result: TxtConversion = {
      metadata: metadata,
      chapterCount: converted.chapterCount,
    };
    return result;
  }

  /** Remove a file, logging rather than throwing: this only ever runs during cleanup. */
  private async removeQuietly(path: string): Promise<void> {
    try {
      await this.storage.remove(path);
    } catch (err) {
      // A leftover temporary file wastes space and is overwritten by the next import of
      // the same book id. Reported rather than swallowed so a stuck deletion is visible:
      // `console` is not used because this project logs through `hilog`.
      hilog.warn(DOMAIN, TAG, 'temporary file cleanup failed for %{public}s: %{public}s',
        path, String(err));
    }
  }

  /**
   * Copy a picker URI into the sandbox under a `.zip` name and extract it.
   *
   * Returns the extract directory, the sandbox copy (which becomes the book file
   * once renamed), and the path of a cover file if the archive held one — the
   * cover is written out during extraction rather than kept in memory, because its
   * bytes are read from the extracted tree anyway.
   */
  private async copyAndExtract(
    uri: string,
    bookId: string,
    warnings: string[],
  ): Promise<ExtractBundle> {
    const workDir: string = this.storage.tempPath(`import-${bookId}`);
    await this.storage.ensureDir(workDir);

    // `.zip` is not cosmetic: `decompressFile` rejects any other extension.
    const sandboxCopy: string = `${workDir}/source.zip`;
    await this.copyInto(uri, sandboxCopy);

    const extractDir: string = `${workDir}/extracted`;
    await this.storage.ensureDir(extractDir);

    try {
      await zlib.decompressFile(sandboxCopy, extractDir);
    } catch (err) {
      // Clean up before rethrowing so a failed import does not leave a partial
      // tree that the next import's directory listing would pick up.
      await this.removeTree(workDir);
      throw fail('解压 EPUB 失败（文件可能已损坏）', err as Object);
    }

    let metadata: EpubMetadata = emptyEpubMetadata();
    let coverTmpPath: string = '';
    try {
      const source: EpubSource = new DirectoryEpubSource(extractDir, []);
      metadata = await parseEpub(source);
      if (metadata.cover !== undefined && metadata.coverExt.length > 0) {
        coverTmpPath = `${workDir}/cover.${metadata.coverExt}`;
        await this.storage.writeBytes(coverTmpPath, metadata.cover);
      }
    } catch (err) {
      warnings.push('无法读取 EPUB 元数据，已使用文件名作为标题');
    }
    // The extracted tree has served its purpose; only the cover file was kept.
    await this.removeTree(extractDir);

    return {
      extractDir: extractDir,
      sandboxCopy: sandboxCopy,
      coverTmpPath: coverTmpPath,
      metadata: metadata,
    };
  }

  /** Copy a URI into the sandbox. Works for both picker URIs and plain paths. */
  private async copyInto(uri: string, destPath: string): Promise<void> {
    let source: fileIo.File | undefined = undefined;
    let target: fileIo.File | undefined = undefined;
    try {
      // A document URI returned by the picker is accepted directly by `fs.open`,
      // which is what avoids needing a manual URI-to-path translation.
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      target = await fileIo.open(
        destPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );

      const stat: fileIo.Stat = await fileIo.stat(source.fd);
      const total: number = stat.size;
      let copied: number = 0;
      const chunk: number = 512 * 1024;

      while (copied < total) {
        const want: number = Math.min(chunk, total - copied);
        const buffer: ArrayBuffer = new ArrayBuffer(want);
        const read: number = await fileIo.read(source.fd, buffer, { offset: copied });
        if (read <= 0) {
          throw new Error('复制时读取提前结束');
        }
        const bytes: Uint8Array = read === want
          ? new Uint8Array(buffer)
          : new Uint8Array(buffer).slice(0, read);
        await fileIo.write(target.fd, bytes.buffer as ArrayBuffer, { offset: copied });
        copied += read;
      }
    } catch (err) {
      throw fail(`复制文件失败（${fileNameFromUri(uri)}）`, err as Object);
    } finally {
      if (source !== undefined) {
        try {
          await fileIo.close(source);
        } catch (closeErr) {
          // Ignored; a failed close must not mask the real error.
        }
      }
      if (target !== undefined) {
        try {
          await fileIo.close(target);
        } catch (closeErr) {
          // Ignored.
        }
      }
    }
  }

  /** Remove a directory and everything under it. Absent is success. */
  private async removeTree(dir: string): Promise<void> {
    try {
      const names: string[] = await fileIo.listFile(dir);
      for (const name of names) {
        const child: string = `${dir}/${name}`;
        let isDirectory: boolean = false;
        try {
          const stat: fileIo.Stat = await fileIo.stat(child);
          isDirectory = stat.isDirectory();
        } catch (statErr) {
          continue;
        }
        if (isDirectory) {
          await this.removeTree(child);
        } else {
          await this.storage.remove(child);
        }
      }
      await fileIo.rmdir(dir);
    } catch (err) {
      // Best effort: a leftover temporary directory wastes space but breaks nothing.
    }
  }
}

/** Paths handed to `FileStorage`, relative to the sandbox root. */
function coverRelDir(): string {
  return 'covers';
}

interface ExtractBundle {
  extractDir: string;
  /** The `.zip`-named copy that becomes the book file once renamed. */
  sandboxCopy: string;
  /** Where the cover was written, or empty when there is none. */
  coverTmpPath: string;
  /** Parsed from the extracted tree, so it is not parsed a second time. */
  metadata: EpubMetadata;
}

/** What a TXT conversion contributed to the row. */
interface TxtConversion {
  metadata: EpubMetadata;
  chapterCount: number;
}

/**
 * `EpubSource` over an extracted directory.
 *
 * `list()` is recursive because EPUB archives keep resources in subdirectories and
 * the cover-name fallback has to see them all.
 */
export class DirectoryEpubSource implements EpubSource {
  private readonly root: string;
  /** Cache of relative paths, filled on first `list()`. */
  private cached: string[];

  constructor(root: string, cached: string[]) {
    this.root = root;
    this.cached = cached;
  }

  async read(path: string): Promise<Uint8Array | undefined> {
    const full: string = `${this.root}/${path}`;
    try {
      const stat: fileIo.Stat = await fileIo.stat(full);
      if (stat.isDirectory() || stat.size === 0) {
        return undefined;
      }
      return await this.readAll(full, stat.size);
    } catch (err) {
      return undefined;
    }
  }

  async list(): Promise<string[]> {
    if (this.cached.length > 0) {
      return this.cached;
    }
    const out: string[] = [];
    await this.walk('', out);
    this.cached = out;
    return out;
  }

  private async walk(relative: string, out: string[]): Promise<void> {
    const dir: string = relative.length > 0 ? `${this.root}/${relative}` : this.root;
    let names: string[] = [];
    try {
      names = await fileIo.listFile(dir);
    } catch (err) {
      return;
    }
    for (const name of names) {
      const childRelative: string = relative.length > 0 ? `${relative}/${name}` : name;
      let isDirectory: boolean = false;
      try {
        const stat: fileIo.Stat = await fileIo.stat(`${dir}/${name}`);
        isDirectory = stat.isDirectory();
      } catch (statErr) {
        continue;
      }
      if (isDirectory) {
        await this.walk(childRelative, out);
      } else {
        out.push(childRelative);
      }
    }
  }

  private async readAll(full: string, size: number): Promise<Uint8Array> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(full, fileIo.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = await fileIo.read(file.fd, buffer);
      const bytes: Uint8Array = new Uint8Array(buffer);
      return read === size ? bytes : bytes.slice(0, read);
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
}

/** Last path segment of a URI or path. */
function fileNameFromUri(uri: string): string {
  const trimmed: string = uri.replace(/\/+$/, '');
  const parts: string[] = trimmed.split('/');
  const last: string = parts.length > 0 ? parts[parts.length - 1] : '';
  // A picker URI may carry a query or fragment.
  const cut: number = last.search(/[?#]/);
  const withoutQuery: string = cut >= 0 ? last.substring(0, cut) : last;
  try {
    return decodeURIComponent(withoutQuery);
  } catch (err) {
    return withoutQuery;
  }
}

/** Lower-case extension of a name, or an empty string. */
function formatFromName(name: string): string {
  return extensionOf(name);
}

/** Name without its extension, used as a fallback title. */
function stripExtension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
