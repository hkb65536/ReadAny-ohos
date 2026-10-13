/**
 * SQL-row adapter for the shared record reader.
 *
 * `RecordReader` itself lives in `core` so that `data` and `sync` can both use it
 * without depending on each other. Only this adapter is data-layer specific,
 * because only the data layer knows about `ResultSet` rows.
 */

import type { RecordReader } from 'core';
import { jsonReader, RecordReader as ReaderBase } from 'core';
import type { Row } from './Rdb';

/** Adapts a SQL row to the shared reader shape. */
export class SqlRecordReader extends ReaderBase {
  private readonly row: Row;

  constructor(row: Row) {
    super();
    this.row = row;
  }

  field(name: string): string | number | boolean | null | undefined {
    return this.row.isNull(name) ? undefined : this.row.str(name);
  }

  raw(name: string): string | number | boolean | null | undefined {
    return this.row.isNull(name) ? undefined : this.row.str(name);
  }

  isNull(name: string): boolean {
    return this.row.isNull(name);
  }

  str(name: string): string {
    return this.row.str(name);
  }

  optStr(name: string): string | undefined {
    return this.row.optStr(name);
  }

  num(name: string, fallback: number): number {
    if (this.row.isNull(name)) {
      return fallback;
    }
    return this.row.num(name);
  }

  bool(name: string): boolean {
    return this.row.bool(name);
  }
}

/** Adapt a SQL row to the shared reader shape. */
export function sqlReader(row: Row): RecordReader {
  return new SqlRecordReader(row);
}

/** Re-exported so callers have one import for both directions. */
export { jsonReader };
