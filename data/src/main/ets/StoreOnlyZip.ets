/**
 * A minimal **store-only** ZIP writer, and the streaming form of it.
 *
 * ## Why this exists rather than `@ohos.zlib`
 *
 * An EPUB must carry `mimetype` as its **first** entry, **uncompressed** (method 0).
 * `@ohos.zlib` cannot express that: `compressFile` and `compressFiles`
 * (`@ohos.zlib.d.ts:908`, `:930`) take one `Options` for the whole archive
 * (`:430-476`), so `CompressLevel.NO_COMPRESSION` (`:60`) stores *every* entry and
 * there is no per-entry method. `compressFiles` does preserve its input array's
 * order, so ordering is reachable — the method is not. There is no entry-level ZIP
 * API anywhere in the OpenHarmony or HMS SDKs.
 *
 * Store-only is a valid EPUB: OCF mandates uncompressed only for `mimetype`, and
 * every reader accepts a fully stored archive. ReadAny made the same choice for the
 * same reason — its `packages/core/src/utils/store-only-zip.ts` is the model for the
 * container written here.
 *
 * ## What is *not* ported
 *
 * ReadAny writes a zero DOS modification date, which decodes as 1980-00-00. This
 * writes 1980-01-01 (`DOS_DATE_1980_01_01`), which is the earliest date the field
 * can represent and is what a strict reader is entitled to expect. Nothing in the
 * EPUB contract depends on it; the difference is deliberate and is covered by
 * `tools/verify-txt-epub.mjs`, which parses the archive this code produces.
 *
 * ## Two forms, one byte layout
 *
 * `buildStoreOnlyZip` materialises a whole archive in memory, which is what the
 * cross-check script exercises. `StoreOnlyZipWriter` writes the same bytes straight
 * to a file, so a converter that produces a chapter at a time never holds the
 * archive — or the book — in memory. Both call the same three layout functions, so
 * the two forms cannot drift.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatZip';

/** One file to place in the archive. */
export interface ZipEntry {
  /** In-archive path, `/`-separated, with no leading slash. */
  name: string;
  /** The file's exact bytes. */
  data: Uint8Array;
}

/**
 * One entry as the central directory needs it.
 *
 * Recorded when the entry's data is written, because a streamed archive cannot go
 * back and measure it: the offset is only knowable at the moment of writing, the
 * CRC only after the bytes are in hand.
 */
export interface ZipRecord {
  name: string;
  crc: number;
  /** Uncompressed size, which for a stored entry is also the compressed size. */
  size: number;
  /** Byte offset of this entry's local header from the start of the archive. */
  offset: number;
}

/** 30-byte local file header, plus the variable-length name that follows it. */
const LOCAL_HEADER_SIZE: number = 30;
/** 46-byte central directory record, plus the same name again. */
const CENTRAL_RECORD_SIZE: number = 46;
/** 22-byte end-of-central-directory record: no comment, so the minimum. */
const EOCD_SIZE: number = 22;

/** `version needed to extract` 2.0: store is legal from 1.0, but 2.0 matches the reference. */
const VERSION_NEEDED: number = 20;
/** Method 0 — stored, uncompressed. */
const METHOD_STORED: number = 0;

const SIGNATURE_LOCAL: number = 0x04034b50;
const SIGNATURE_CENTRAL: number = 0x02014b50;
const SIGNATURE_EOCD: number = 0x06054b50;

/**
 * DOS date for 1980-01-01: `(year-1980) << 9 | month << 5 | day`.
 *
 * See the module comment for why this is not zero.
 */
const DOS_DATE_1980_01_01: number = (0 << 9) | (1 << 5) | 1;

/** UTF-8 bytes of a string. */
function utf8Bytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

/**
 * An `ArrayBuffer` that is exactly `bytes`.
 *
 * `fileIo.write` takes an `ArrayBuffer` and writes *all* of it, so a view whose
 * backing buffer is larger than the view — anything produced by `slice` on a bigger
 * array, or by a subarray — would write trailing bytes from outside the view. Every
 * array this module passes is exact-sized, and this makes that a checked property
 * rather than an assumption, at the cost of a copy only when it is not.
 */
function exactBuffer(bytes: Uint8Array): ArrayBuffer {
  if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
    return bytes.buffer as ArrayBuffer;
  }
  return bytes.slice().buffer as ArrayBuffer;
}

/** Little-endian `uint16` at `at`. */
function writeU16(target: Uint8Array, at: number, value: number): void {
  target[at] = value & 0xff;
  target[at + 1] = (value >>> 8) & 0xff;
}

/** Little-endian `uint32` at `at`. */
function writeU32(target: Uint8Array, at: number, value: number): void {
  target[at] = value & 0xff;
  target[at + 1] = (value >>> 8) & 0xff;
  target[at + 2] = (value >>> 16) & 0xff;
  target[at + 3] = (value >>> 24) & 0xff;
}

/**
 * CRC-32 (IEEE 802.3, reflected, polynomial `0xedb88320`) as a ZIP requires it.
 *
 * Implemented here rather than taken from `zlib.createChecksumSync().crc32()`
 * (`@ohos.zlib.d.ts:1152`) because that API is asynchronous, takes an `ArrayBuffer`
 * and returns a `Promise` — three round trips through the runtime for a value this
 * loop computes in one pass over bytes that are already in hand. The table is the
 * standard one and is built once at module load.
 */
const CRC_TABLE: Uint32Array = buildCrcTable();

function buildCrcTable(): Uint32Array {
  const table: Uint32Array = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c: number = i;
    for (let j = 0; j < 8; j++) {
      c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  return table;
}

/** CRC-32 of `data`, as an unsigned 32-bit number. */
export function crc32Of(data: Uint8Array): number {
  let crc: number = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = CRC_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * A local file header together with its entry name.
 *
 * Returned as one buffer because they are always written together and a single
 * write per entry is what keeps a 1800-chapter archive from issuing 3600 syscalls.
 */
export function localHeaderBytes(name: string, crc: number, size: number): Uint8Array {
  const nameBytes: Uint8Array = utf8Bytes(name);
  const out: Uint8Array = new Uint8Array(LOCAL_HEADER_SIZE + nameBytes.length);
  let at: number = 0;
  writeU32(out, at, SIGNATURE_LOCAL); at += 4;
  writeU16(out, at, VERSION_NEEDED); at += 2;
  writeU16(out, at, 0); at += 2;                       // general purpose flags
  writeU16(out, at, METHOD_STORED); at += 2;
  writeU16(out, at, 0); at += 2;                       // modification time
  writeU16(out, at, DOS_DATE_1980_01_01); at += 2;
  writeU32(out, at, crc); at += 4;
  writeU32(out, at, size); at += 4;                    // compressed size
  writeU32(out, at, size); at += 4;                    // uncompressed size
  writeU16(out, at, nameBytes.length); at += 2;
  writeU16(out, at, 0); at += 2;                       // extra field length
  out.set(nameBytes, at);
  return out;
}

/**
 * A central directory record together with its entry name.
 *
 * `madeBy` is `VERSION_NEEDED` as well: this writer has no host-system byte to
 * declare (the high byte says FAT/MS-DOS), and a value the reader already accepts
 * is better than one it has to interpret.
 */
export function centralRecordBytes(record: ZipRecord): Uint8Array {
  const nameBytes: Uint8Array = utf8Bytes(record.name);
  const out: Uint8Array = new Uint8Array(CENTRAL_RECORD_SIZE + nameBytes.length);
  let at: number = 0;
  writeU32(out, at, SIGNATURE_CENTRAL); at += 4;
  writeU16(out, at, VERSION_NEEDED); at += 2;          // version made by
  writeU16(out, at, VERSION_NEEDED); at += 2;          // version needed
  writeU16(out, at, 0); at += 2;                       // general purpose flags
  writeU16(out, at, METHOD_STORED); at += 2;
  writeU16(out, at, 0); at += 2;                       // modification time
  writeU16(out, at, DOS_DATE_1980_01_01); at += 2;
  writeU32(out, at, record.crc); at += 4;
  writeU32(out, at, record.size); at += 4;
  writeU32(out, at, record.size); at += 4;
  writeU16(out, at, nameBytes.length); at += 2;
  writeU16(out, at, 0); at += 2;                       // extra field length
  writeU16(out, at, 0); at += 2;                       // file comment length
  writeU16(out, at, 0); at += 2;                       // disk number start
  writeU16(out, at, 0); at += 2;                       // internal attributes
  writeU32(out, at, 0); at += 4;                       // external attributes
  writeU32(out, at, record.offset); at += 4;
  out.set(nameBytes, at);
  return out;
}

/**
 * The end-of-central-directory record.
 *
 * No Zip64: an EPUB is bounded by the book it was made from and a 4 GiB archive
 * would have exhausted a phone's storage long before this record overflowed.
 */
export function endOfCentralDirectoryBytes(
  entryCount: number,
  centralSize: number,
  centralOffset: number,
): Uint8Array {
  const out: Uint8Array = new Uint8Array(EOCD_SIZE);
  let at: number = 0;
  writeU32(out, at, SIGNATURE_EOCD); at += 4;
  writeU16(out, at, 0); at += 2;                       // this disk number
  writeU16(out, at, 0); at += 2;                       // disk with central directory
  writeU16(out, at, entryCount); at += 2;              // entries on this disk
  writeU16(out, at, entryCount); at += 2;              // entries in total
  writeU32(out, at, centralSize); at += 4;
  writeU32(out, at, centralOffset); at += 4;
  writeU16(out, at, 0);                                // comment length
  return out;
}

/**
 * Build a complete archive in memory.
 *
 * Entries are written in the given order, and the first one should be `mimetype`.
 * For anything large enough that holding the archive (and the book behind it) is a
 * concern, use `StoreOnlyZipWriter` instead.
 */
export function buildStoreOnlyZip(entries: ZipEntry[]): Uint8Array {
  const headers: Uint8Array[] = [];
  const records: ZipRecord[] = [];
  let total: number = 0;

  for (const entry of entries) {
    const crc: number = crc32Of(entry.data);
    const header: Uint8Array = localHeaderBytes(entry.name, crc, entry.data.length);
    const record: ZipRecord = {
      name: entry.name,
      crc: crc,
      size: entry.data.length,
      offset: total,
    };
    headers.push(header);
    records.push(record);
    total += header.length + entry.data.length;
  }

  const central: Uint8Array[] = [];
  const centralStart: number = total;
  let centralSize: number = 0;
  for (const record of records) {
    const block: Uint8Array = centralRecordBytes(record);
    central.push(block);
    centralSize += block.length;
  }
  total += centralSize + EOCD_SIZE;

  const out: Uint8Array = new Uint8Array(total);
  let at: number = 0;
  for (let i = 0; i < entries.length; i++) {
    const header: Uint8Array = headers[i];
    out.set(header, at);
    at += header.length;
    out.set(entries[i].data, at);
    at += entries[i].data.length;
  }
  for (const block of central) {
    out.set(block, at);
    at += block.length;
  }
  out.set(endOfCentralDirectoryBytes(records.length, centralSize, centralStart), at);
  return out;
}

/**
 * A store-only ZIP written straight to a file, one entry at a time.
 *
 * The point is memory: a 9.7 MB book becomes a 9.7 MB archive, and a converter that
 * had to materialise either would need both alive at once. Here the largest thing
 * ever held is the entry currently being added.
 *
 * Not reusable after `close()`: the offsets and CRCs of a closed archive are gone,
 * and silently starting a second one in the same file would produce an archive whose
 * central directory describes only its tail.
 */
export class StoreOnlyZipWriter {
  private readonly path: string;
  private file: fileIo.File | undefined = undefined;
  private offset: number = 0;
  private records: ZipRecord[] = [];

  constructor(path: string) {
    this.path = path;
  }

  /** Create (or truncate) the archive file. */
  async open(): Promise<void> {
    this.file = await fileIo.open(
      this.path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
    );
    this.offset = 0;
    this.records = [];
  }

  /** The open handle, or a throw naming the mistake rather than a null dereference. */
  private handle(): fileIo.File {
    const file: fileIo.File | undefined = this.file;
    if (file === undefined) {
      throw new Error(`ZIP 写入器尚未打开：${this.path}`);
    }
    return file;
  }

  /** Number of entries written so far. */
  entryCount(): number {
    return this.records.length;
  }

  /** Append one stored entry. */
  async addEntry(name: string, data: Uint8Array): Promise<void> {
    const file: fileIo.File = this.handle();
    const crc: number = crc32Of(data);
    const header: Uint8Array = localHeaderBytes(name, crc, data.length);
    await fileIo.write(file.fd, exactBuffer(header));
    if (data.length > 0) {
      await fileIo.write(file.fd, exactBuffer(data));
    }
    const record: ZipRecord = {
      name: name,
      crc: crc,
      size: data.length,
      offset: this.offset,
    };
    this.records.push(record);
    this.offset += header.length + data.length;
  }

  /** Write the central directory and the end record, then close the file. */
  async close(): Promise<void> {
    const file: fileIo.File = this.handle();
    const centralStart: number = this.offset;
    let centralSize: number = 0;
    for (const record of this.records) {
      const block: Uint8Array = centralRecordBytes(record);
      await fileIo.write(file.fd, exactBuffer(block));
      centralSize += block.length;
    }
    await fileIo.write(
      file.fd,
      exactBuffer(endOfCentralDirectoryBytes(this.records.length, centralSize, centralStart)),
    );
    await fileIo.close(file);
    this.file = undefined;
  }

  /**
   * Close the handle without writing a central directory.
   *
   * For the failure path: an archive with no end record is not a valid ZIP, which is
   * exactly what a partly-written one should be. The caller removes the file; this
   * only guarantees the descriptor is released, and it never throws, because a
   * cleanup failure must not replace the error that caused the cleanup.
   */
  async abort(): Promise<void> {
    const file: fileIo.File | undefined = this.file;
    if (file === undefined) {
      return;
    }
    this.file = undefined;
    try {
      await fileIo.close(file);
    } catch (err) {
      // The descriptor is released by process exit at the latest, and `abort` runs
      // while a real error is already unwinding. Logged rather than swallowed so a
      // leak is visible somewhere. `console` is not used: this project logs through
      // `hilog` so a device run can capture it.
      hilog.warn(DOMAIN, TAG, 'ZIP writer close failed: %{public}s', String(err));
    }
  }
}
