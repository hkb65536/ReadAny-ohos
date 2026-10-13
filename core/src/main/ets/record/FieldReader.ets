/**
 * Field reading over a record.
 *
 * A "record" is one flat row of data: a SQL result row locally, or a JSON object
 * parsed from a peer's sync file remotely. Both paths must agree on how a field is
 * coerced, otherwise a synced book would render differently from a locally
 * imported one.
 *
 * This lives in `core` because both `data` and `sync` need it and neither may
 * depend on the other.
 *
 * `RecordReader` is an abstract class rather than an interface on purpose: ArkTS
 * refuses an object literal as the value of an interface type when that interface
 * is imported across a module boundary (`arkts-no-untyped-obj-literals`), so the
 * only workable shape here is a nominal class that implementations extend.
 */

/**
 * Field access with the widest type the sync protocol can carry.
 *
 * Returns `undefined` for a field that is absent — as opposed to present and
 * SQL NULL. The distinction is load-bearing in `shouldApplyRemoteRecord`, which
 * only consults `deleted_at` when the peer actually sent it.
 */
export abstract class FieldReader {
  abstract field(name: string): string | number | boolean | null | undefined;
}

/** Typed, null-aware access used by the domain mappers. */
export abstract class RecordReader extends FieldReader {
  /** Raw value, or `undefined` when the field is absent or null. */
  abstract raw(name: string): string | number | boolean | null | undefined;
  /** String value; empty string when absent or null. */
  abstract str(name: string): string;
  /** String value, or `undefined` when absent, null or empty. */
  abstract optStr(name: string): string | undefined;
  /** Number value; `fallback` when absent, null or unparseable. */
  abstract num(name: string, fallback: number): number;
  /** Boolean value from a 0/1 integer or a JSON boolean. */
  abstract bool(name: string): boolean;
  /** True when the field is absent or null. */
  abstract isNull(name: string): boolean;
}

/** Coerce a JSON value to the reader's raw type. */
function rawValue(value: Object | null | undefined): string | number | boolean | null | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  // Objects and arrays are stored as JSON text in a column, so stringify to match
  // what the SQL path would have returned.
  return JSON.stringify(value);
}

function asString(value: string | number | boolean | null | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  return typeof value === 'string' ? value : String(value);
}

function asNumber(value: string | number | boolean | null | undefined, fallback: number): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'boolean') {
    return value ? 1 : 0;
  }
  const parsed: number = Number(value);
  return Number.isNaN(parsed) ? fallback : parsed;
}

function asBool(value: string | number | boolean | null | undefined): boolean {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  const lower: string = value.toLowerCase();
  return lower === '1' || lower === 'true';
}

/**
 * Reader over a record parsed from a peer's JSON sync file.
 *
 * The record's values are `Object | null`, not `Object`: a JSON object parsed from
 * the wire genuinely holds `null` for a column the peer sent as SQL NULL, and
 * `rawValue` has always handled that case — the annotation was simply narrower than
 * the implementation. `null` reads as `undefined` here (absent and NULL are the
 * same to a field reader), which is the documented behaviour of `field`.
 */
export class JsonRecordReader extends RecordReader {
  private readonly record: Record<string, Object | null>;

  constructor(record: Record<string, Object | null>) {
    super();
    this.record = record;
  }

  private value(name: string): string | number | boolean | null | undefined {
    return rawValue(this.record[name]);
  }

  field(name: string): string | number | boolean | null | undefined {
    return this.value(name);
  }

  raw(name: string): string | number | boolean | null | undefined {
    return this.value(name);
  }

  isNull(name: string): boolean {
    return this.value(name) === undefined;
  }

  str(name: string): string {
    return asString(this.value(name));
  }

  optStr(name: string): string | undefined {
    const text: string = asString(this.value(name));
    return text.length > 0 ? text : undefined;
  }

  num(name: string, fallback: number): number {
    return asNumber(this.value(name), fallback);
  }

  bool(name: string): boolean {
    return asBool(this.value(name));
  }
}

/**
 * Build a reader over a plain object, for records parsed from remote JSON.
 *
 * The parameter is `Record<string, Object | null>` so that a caller holding a
 * null-capable row type (the v1 per-device protocol's `WireRow`) can hand it over
 * directly. A `Record<string, Object>` caller is unaffected: it is assignable to
 * the wider type.
 */
export function jsonReader(record: Record<string, Object | null>): RecordReader {
  return new JsonRecordReader(record);
}
