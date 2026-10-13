/**
 * Byte/string conversion for sync payloads.
 *
 * `WebDavClient.getBytes` returns what `@ohos.net.http` handed over in an
 * `ArrayBuffer`; the JSON documents in the sync tree arrive that way because
 * `expectDataType: ARRAY_BUFFER` is requested for binary transfers. Decoding is
 * kept here rather than in the client so the client stays a pure transport.
 */

import { util } from '@kit.ArkTS';

/** Decode UTF-8 bytes into a string. */
export function utf8Decode(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: false }).decodeToString(bytes);
}

/** Encode a string as UTF-8 bytes. */
export function utf8Encode(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

/**
 * How reading one remote JSON document turned out.
 *
 * `ABSENT` and `UNPARSEABLE` are kept apart deliberately. A 404 — or a genuinely
 * empty body — means "there is no document", which is the normal first-run state
 * and is safe to write over. A document that *is* there and is not JSON (a
 * captive-portal page, a proxy-mangled body, a truncated transfer, an undecoded
 * encoding) must never be read as that: a caller that does rebuilds the file from
 * its own rows and erases everything the peer had in it.
 */
export enum JsonReadOutcome {
  /** No document: a 404, or an empty body. Legitimately empty. */
  ABSENT = 'absent',
  /** A JSON object was read. */
  PARSED = 'parsed',
  /** A body arrived, but it is not a JSON object. Never write over it. */
  UNPARSEABLE = 'unparseable',
}

/**
 * One remote JSON read, carrying absence and corruption as separate states.
 *
 * A class rather than an interface: ArkTS rejects an object literal that
 * implements an interface declared in another module, and this type crosses from
 * `sync` into `data` (see `docs/arkts-constraints.md` §2.0).
 */
export class JsonDocument {
  readonly outcome: JsonReadOutcome;
  readonly record: Record<string, Object> | undefined;
  /** The first characters of an unparseable body, for the error message. */
  readonly excerpt: string;

  constructor(
    outcome: JsonReadOutcome,
    record: Record<string, Object> | undefined,
    excerpt: string,
  ) {
    this.outcome = outcome;
    this.record = record;
    this.excerpt = excerpt;
  }
}

/** How much of an unparseable body is quoted back to the user. */
const EXCERPT_LENGTH: number = 80;

/** A short, single-line rendering of a body, for an error message. */
export function jsonExcerptOf(text: string): string {
  const flattened: string = text.replace(/\s+/g, ' ').trim();
  return flattened.length > EXCERPT_LENGTH
    ? `${flattened.substring(0, EXCERPT_LENGTH)}...`
    : flattened;
}

/**
 * Read a JSON object, keeping "absent" apart from "unparseable".
 *
 * Every caller that follows the read with a write must use this and refuse the
 * write on `UNPARSEABLE`; `parseJsonRecord` is the read-only convenience and
 * deliberately does not distinguish the two.
 */
export function readJsonDocument(text: string): JsonDocument {
  if (text.length === 0) {
    return new JsonDocument(JsonReadOutcome.ABSENT, undefined, '');
  }
  try {
    const parsed: Object = JSON.parse(text) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return new JsonDocument(JsonReadOutcome.UNPARSEABLE, undefined, jsonExcerptOf(text));
    }
    return new JsonDocument(JsonReadOutcome.PARSED, parsed as Record<string, Object>, '');
  } catch (err) {
    return new JsonDocument(JsonReadOutcome.UNPARSEABLE, undefined, jsonExcerptOf(text));
  }
}

/**
 * Parse a JSON document, returning `undefined` instead of throwing.
 *
 * **Read-only paths only.** This merges "absent" with "unparseable", so it must
 * never be used where the answer decides whether to *write* a remote document: a
 * corrupt body would then be rebuilt from local rows alone and every row it held
 * from a peer would be lost. Use `readJsonDocument` there.
 */
export function parseJsonRecord(text: string): Record<string, Object> | undefined {
  return readJsonDocument(text).record;
}
