/**
 * File hashing for cover change detection.
 *
 * Only covers are hashed. Book files are compared by presence and size instead,
 * because a book can be hundreds of megabytes and hashing it on every sync would
 * cost more than re-uploading the cover it is meant to protect.
 *
 * The digest is streamed in chunks rather than read whole: `createMd` supports
 * incremental `updateSync`, and a single-shot read of a large file is exactly the
 * memory pressure this client cannot afford on a phone.
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';

/** Algorithm name accepted by `createMd` on HarmonyOS. */
const DIGEST_ALGORITHM: string = 'SHA256';

/** Chunk size for streaming. 64 KiB keeps peak memory flat regardless of file size. */
const CHUNK_BYTES: number = 64 * 1024;

const HEX_DIGITS: string = '0123456789abcdef';

/** Compute the SHA-256 of a file as lowercase hex. */
export async function hashFileSha256(path: string): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd(DIGEST_ALGORITHM);

  let file: fileIo.File | undefined = undefined;
  try {
    file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    const stat: fileIo.Stat = await fileIo.stat(path);
    let remaining: number = stat.size;

    while (remaining > 0) {
      const want: number = remaining < CHUNK_BYTES ? remaining : CHUNK_BYTES;
      const buffer: ArrayBuffer = new ArrayBuffer(want);
      const read: number = await fileIo.read(file.fd, buffer);
      if (read <= 0) {
        // Short read on a file that is still growing or was truncated under us.
        // Hashing a partial file would produce a digest that never matches the
        // remote hash again, so this is a hard failure rather than a partial hash.
        throw new Error(`读取 ${path} 时提前结束（剩余 ${remaining} 字节）`);
      }
      const chunk: Uint8Array = read === want ? new Uint8Array(buffer) : new Uint8Array(buffer).slice(0, read);
      // `updateSync` takes a DataBlob; the cast is the documented shape.
      const blob: cryptoFramework.DataBlob = { data: chunk };
      md.updateSync(blob);
      remaining -= read;
    }

    const digest: cryptoFramework.DataBlob = md.digestSync();
    return toHex(digest.data);
  } finally {
    if (file !== undefined) {
      try {
        await fileIo.close(file);
      } catch (closeErr) {
        // A failed close must not replace the real error.
      }
    }
  }
}

/** Lowercase hex of a byte array. */
export function toHex(bytes: Uint8Array): string {
  const out: string[] = [];
  for (let i = 0; i < bytes.length; i++) {
    const value: number = bytes[i];
    out.push(HEX_DIGITS.charAt((value >> 4) & 0x0f));
    out.push(HEX_DIGITS.charAt(value & 0x0f));
  }
  return out.join('');
}
