/**
 * Error model for InkBoat.
 *
 * ArkTS has no `Error` subclassing across module boundaries that preserves
 * `instanceof` reliably in every build mode, so the kind is carried in a plain
 * field and callers switch on `kind` rather than on the class.
 */

export enum SyncErrorKind {
  /** Missing or rejected credentials. */
  AUTH = 'auth',
  /** Authenticated but not permitted. */
  FORBIDDEN = 'forbidden',
  /** Remote path does not exist. */
  NOT_FOUND = 'not-found',
  /** Server refused the HTTP method (405/501). */
  METHOD_NOT_ALLOWED = 'method-not-allowed',
  /** Request timed out. */
  TIMEOUT = 'timeout',
  /** DNS / TCP / connection reset. */
  NETWORK = 'network',
  /** TLS handshake or certificate problem. */
  TLS = 'tls',
  /** Any other 5xx. */
  SERVER = 'server',
  /** Other HTTP status. */
  HTTP = 'http',
  /** Response body could not be parsed. */
  PARSE = 'parse',
  /** Local database failure. */
  DATABASE = 'database',
  /** Local file system failure. */
  FILE = 'file',
  /** Settings are incomplete or inconsistent. */
  CONFIG = 'config',
  /** Protocol version we do not understand. */
  UNSUPPORTED = 'unsupported',
  /** Anything not covered above. */
  UNKNOWN = 'unknown',
}

export class InkBoatError extends Error {
  readonly kind: SyncErrorKind;
  readonly status: number;
  readonly method: string;
  readonly url: string;

  constructor(
    kind: SyncErrorKind,
    message: string,
    status: number = 0,
    method: string = '',
    url: string = '',
  ) {
    super(message);
    this.name = 'InkBoatError';
    this.kind = kind;
    this.status = status;
    this.method = method;
    this.url = url;
  }

  /** True when retrying the same request later may succeed. */
  isRetryable(): boolean {
    return this.kind === SyncErrorKind.SERVER
      || this.kind === SyncErrorKind.TIMEOUT
      || this.kind === SyncErrorKind.NETWORK
      || this.status === 429;
  }

  /** True when the user must re-enter credentials before syncing can work. */
  needsCredentials(): boolean {
    return this.kind === SyncErrorKind.AUTH || this.kind === SyncErrorKind.FORBIDDEN;
  }
}

/** Map an HTTP status code to the closest error kind. */
export function kindFromStatus(status: number): SyncErrorKind {
  if (status === 401) {
    return SyncErrorKind.AUTH;
  }
  if (status === 403) {
    return SyncErrorKind.FORBIDDEN;
  }
  if (status === 404 || status === 410) {
    return SyncErrorKind.NOT_FOUND;
  }
  if (status === 405 || status === 501) {
    return SyncErrorKind.METHOD_NOT_ALLOWED;
  }
  if (status === 408 || status === 504) {
    return SyncErrorKind.TIMEOUT;
  }
  if (status >= 500) {
    return SyncErrorKind.SERVER;
  }
  return SyncErrorKind.HTTP;
}
