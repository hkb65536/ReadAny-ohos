/**
 * Identifier helpers.
 *
 * The platform layer injects a UUID generator (HOS `util.generateRandomUUID`)
 * at start-up; the fallback below keeps the core module usable in unit tests
 * and in any environment where the platform hook has not been installed yet.
 *
 * IDs must be lowercase UUID v4: the remote book folder parser
 * (`{sanitized-title}-{bookId}`) validates the last 36 characters against the
 * v4 shape, so changing this format breaks interoperability with the existing
 * ReadAny clients.
 */

export type UuidGenerator = () => string;

const UUID_V4_RE: RegExp =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** Shape-only check used by the remote folder parser (any v4-ish 8-4-4-4-12). */
const UUID_SHAPE_RE: RegExp =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

let injected: UuidGenerator | null = null;

/** Install the platform UUID generator. Called once from the ability layer. */
export function setUuidGenerator(generator: UuidGenerator): void {
  injected = generator;
}

/** True when `value` has the 8-4-4-4-12 UUID shape used in remote paths. */
export function isUuidV4(value: string): boolean {
  return UUID_SHAPE_RE.test(value);
}

/** Strict RFC 4122 version-4 check. */
export function isStrictUuidV4(value: string): boolean {
  return UUID_V4_RE.test(value);
}

const HEX: string = '0123456789abcdef';

function randomHex(byteCount: number): string {
  const out: string[] = [];
  for (let i = 0; i < byteCount; i++) {
    out.push(HEX.charAt(Math.floor(Math.random() * 16)));
  }
  return out.join('');
}

/** Generate a new identifier. Prefers the injected platform generator. */
export function generateId(): string {
  if (injected !== null) {
    const value: string = injected();
    if (value.length > 0) {
      return value.toLowerCase();
    }
  }
  // Fallback: shape-correct v4 built from Math.random. Only reachable before
  // the ability layer installs the real generator, or inside unit tests.
  return `${randomHex(8)}-${randomHex(4)}-4${randomHex(3)}-8${randomHex(3)}-${randomHex(12)}`;
}
