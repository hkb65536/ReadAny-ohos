/**
 * WebDAV client over `@ohos.net.http`.
 *
 * Ported from ReadAny `packages/core/src/sync/webdav-client.ts`.
 *
 * Why `customMethod` matters: WebDAV needs `PROPFIND`, `MKCOL`, `MOVE` and
 * `DELETE`, none of which are in `http.RequestMethod`. HarmonyOS exposes
 * `HttpRequestOptions.customMethod` (API 23+) precisely for the "WebDAV
 * extension protocol", and it takes precedence over `method`. Without it the
 * entire sync feature is impossible on this platform — so `allowInsecure` aside,
 * this file is the single point of failure for the whole feature.
 *
 * Behaviour deliberately preserved from the reference client:
 *  - `207 Multi-Status` counts as success, like any other 2xx.
 *  - Retries only on 401-after-a-previous-success, 429 and 5xx, backing off
 *    500ms / 1s / 2s. Network and timeout failures are NOT retried: they may
 *    already have consumed the full timeout, so retrying multiplies latency.
 *  - `MKCOL` and `PUT` self-heal a missing parent collection instead of failing.
 *  - `DELETE` treats 404 as success (idempotent).
 *  - `MOVE` sends `Overwrite: F` and refuses to clobber.
 *  - Basic auth only, UTF-8 credentials.
 */

import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InkBoatError, kindFromStatus, SyncErrorKind } from 'core';
import type { RemoteResource, WebDavConfig } from './WebDavTypes';
import {
  buildRequestUrl,
  filenameFromPath,
  normalizeWebDavPath,
  pathnameOf,
  sanitizeWebDavUrl,
  toCollectionPath,
  toCollectionRequestPath,
} from './RemotePaths';
import { parsePropfindDetailed, ParsedListing } from './PropfindParser';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatDav';

/**
 * How many characters of a response body a diagnostic line quotes.
 *
 * Long enough for `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">` and the
 * first `<D:href>`, which is what tells a multistatus apart from an HTML
 * directory index or an error page; short enough that one line stays readable in
 * `hilog` and in a pasted report.
 */
const BODY_EXCERPT_LENGTH: number = 200;

const DEFAULT_TIMEOUT_MS: number = 30_000;
/**
 * Timeout for a whole-file transfer. An order of magnitude above the metadata
 * timeout because a large book over a slow link is legitimately slow, and the
 * streaming download applies it as a wall-clock bound.
 */
export const TRANSFER_TIMEOUT_MS: number = 300_000;
const DIRECTORY_PROBE_TIMEOUT_MS: number = 5_000;
const PING_TIMEOUT_MS: number = 10_000;

/**
 * Sentinel status meaning "the wall-clock timer won".
 *
 * A value rather than a rejection so a streaming transfer that finishes just after
 * the timer fires still wins the race — the same reasoning behind `TimedResponse`.
 */
const HTTP_TIMEOUT_SENTINEL: number = -1;

/**
 * Maximum response body the framework will accept, in bytes.
 *
 * The default is **5 MiB**, which a realistic library overruns: a `PROPFIND` on a
 * large `/readany/data/books/` returns one `<D:response>` per file, and the
 * `file-manifest.json` grows with the collection. Exceeding the limit surfaces as a
 * truncated body or an error rather than a partial success, so every request here
 * asks for the documented maximum.
 *
 * 100 MiB is also the ceiling `@ohos.net.http` accepts, so this is as far as the
 * value can be raised. A single response larger than that is not supported by the
 * framework at all; the mitigation is chunking the work — `getToFile` streams, and a
 * future range-request path would split a very large file into several responses.
 */
const MAX_RESPONSE_BYTES: number = 100 * 1024 * 1024;

const RETRY_MAX_ATTEMPTS: number = 3;
const RETRY_BASE_DELAY_MS: number = 500;

/** PROPFIND body: only the resource type, which every server must support. */
const PROPFIND_RESOURCETYPE_BODY: string =
  '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>';

/** PROPFIND body for listings: adds size / mtime / etag. */
const PROPFIND_LISTING_BODY: string =
  '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop>' +
  '<D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:getetag/>' +
  '</D:prop></D:propfind>';

/**
 * Sentinel result of `withTimeout`: `timedOut` is true when the timer won the
 * race and `response` must be ignored.
 *
 * A small wrapper is used instead of rejecting from the timer, because ArkTS
 * refuses to pass a subclass instance to a parameter typed as the base class
 * (`arkts-no-structural-typing`), which makes the usual `reject(new MyError())`
 * pattern uncompilable.
 */
interface TimedResponse {
  timedOut: boolean;
  response: http.HttpResponse | undefined;
}

/** Minimal shape of an HTTP response, so the client is testable. */
export interface DavResponse {
  status: number;
  statusText: string;
  body: string;
  bytes: Uint8Array;
  contentType: string;
}

/** What the client needs from the transport. Swapped out in unit tests. */
export interface HttpTransport {
  send(
    method: string,
    url: string,
    headers: Map<string, string>,
    body: string | ArrayBuffer | undefined,
    timeoutMs: number,
    wantBytes: boolean,
  ): Promise<DavResponse>;

  /**
   * Stream a GET body straight to a file.
   *
   * Declared on the transport rather than only on `WebDavClient` because the
   * streaming events (`dataReceive` / `dataEnd` / `headersReceive`) have no
   * equivalent in the request/response shape of `send`. Expressing this as a `send`
   * call would mean buffering the body, which is the thing it exists to avoid.
   *
   * Returns the number of bytes written.
   */
  getToFile(
    url: string,
    headers: Map<string, string>,
    destPath: string,
    timeoutMs: number,
    onProgress?: (received: number, total: number) => void,
  ): Promise<number>;
}

/** `@ohos.net.http`-backed transport. This is what runs on device. */
export class HarmonyHttpTransport implements HttpTransport {
  readonly allowInsecure: boolean;

  constructor(allowInsecure: boolean) {
    this.allowInsecure = allowInsecure;
  }

  async send(
    method: string,
    url: string,
    headers: Map<string, string>,
    body: string | ArrayBuffer | undefined,
    timeoutMs: number,
    wantBytes: boolean,
  ): Promise<DavResponse> {
    let effectiveUrl: string = url;
    if (this.allowInsecure && effectiveUrl.startsWith('https://')) {
      // Mirrors the mobile client: "allow insecure" means fall back to plain
      // HTTP, which is what self-hosted DAV boxes with broken certs need.
      effectiveUrl = `http://${effectiveUrl.substring('https://'.length)}`;
    }

    const headerObject: Record<string, string> = {};
    headers.forEach((value: string, key: string): void => {
      headerObject[key] = value;
    });

    const request: http.HttpRequest = http.createHttp();
    try {
      // `method` is omitted for WebDAV extensions; see `baseMethodFor`.
      const options: http.HttpRequestOptions = buildOptions(
        method,
        headerObject,
        body,
        timeoutMs,
        wantBytes,
      );

      const timed: TimedResponse = await this.withTimeout(
        request.request(effectiveUrl, options),
        timeoutMs,
      );
      if (timed.timedOut) {
        throw new Error(`${method} ${effectiveUrl} timeout after ${timeoutMs}ms`);
      }
      const response: http.HttpResponse = timed.response as http.HttpResponse;

      const status: number = response.responseCode as number;
      const contentTypeRaw: string | undefined = this.headerValue(response.header, 'content-type');
      const contentType: string = contentTypeRaw !== undefined ? contentTypeRaw : '';

      let text: string = '';
      let bytes: Uint8Array = new Uint8Array(0);
      const result: string | Object | ArrayBuffer = response.result;
      if (result instanceof ArrayBuffer) {
        bytes = new Uint8Array(result);
      } else if (typeof result === 'string') {
        text = result;
      } else if (result !== null && result !== undefined) {
        text = JSON.stringify(result);
      }

      return {
        status: status,
        statusText: this.headerValue(response.header, 'status-line') ?? '',
        body: text,
        bytes: bytes,
        contentType: contentType,
      };
    } catch (err) {
      if (err instanceof InkBoatError) {
        throw classifyError(err, 'WebDAV 请求失败');
      }
      throw this.fromTransportError(err, method, effectiveUrl);
    } finally {
      request.destroy();
    }
  }
  /** Read one response header, case-insensitively. */
  private headerValue(header: Object, name: string): string | undefined {
    const record: Record<string, string> = header as Record<string, string>;
    const direct: string | undefined = record[name];
    if (direct !== undefined) {
      return direct;
    }
    const lower: string = name.toLowerCase();
    const keys: string[] = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === lower) {
        return record[keys[i]];
      }
    }
    return undefined;
  }

  /**
   * Bound a request in wall-clock time.
   *
   * A redundant guard, kept deliberately. The Network Kit documentation states that
   * `readTimeout` is *the total time from request start to request end*, including DNS,
   * connect and transfer — so the framework already enforces a real deadline, and this
   * wrapper is not the only thing standing between a trickling server and a hung call.
   *
   * It is still worth having: it bounds the JavaScript side, so a promise that never
   * settles is caught even if the native layer misbehaves, and it produces a
   * `SyncErrorKind.TIMEOUT` rather than whatever word the stack would use.
   *
   * See `TimedResponse` for why the timer does not simply reject. The generous
   * slack after the timer fires lets an in-flight response win the race rather
   * than being reported as a timeout that had already completed.
   */
  private async withTimeout(
    work: Promise<http.HttpResponse>,
    timeoutMs: number,
  ): Promise<TimedResponse> {
    let timer: number = -1;
    const timeout: Promise<TimedResponse> = new Promise(
      (resolve: (value: TimedResponse) => void): void => {
        timer = setTimeout((): void => {
          resolve({ timedOut: true, response: undefined });
        }, timeoutMs);
      },
    );
    const wrapped: Promise<TimedResponse> = work.then(
      (value: http.HttpResponse): TimedResponse => {
        return { timedOut: false, response: value };
      },
    );

    try {
      return await Promise.race([wrapped, timeout]);
    } finally {
      if (timer !== -1) {
        clearTimeout(timer);
      }
    }
  }

  /** Classify a thrown transport error into an `InkBoatError`. */
  private fromTransportError(err: Object, method: string, url: string): InkBoatError {
    const message: string = err instanceof Error ? err.message : JSON.stringify(err);
    const lower: string = message.toLowerCase();

    let kind: SyncErrorKind = SyncErrorKind.NETWORK;
    if (lower.includes('timeout') || lower.includes('timed out')) {
      kind = SyncErrorKind.TIMEOUT;
    } else if (lower.includes('ssl') || lower.includes('certificate') || lower.includes('tls')) {
      kind = SyncErrorKind.TLS;
    } else if (lower.includes('resolve') || lower.includes('dns') || lower.includes('host')) {
      kind = SyncErrorKind.NETWORK;
    }
    return new InkBoatError(kind, `${method} ${url} 失败：${message}`, 0, method, url);
  }

  /**
   * Download straight to a file, without holding the body in memory.
   *
   * `send` reads the whole response into one `ArrayBuffer`. That is fine for a
   * metadata document and wrong for a book: a 500 MB PDF would need 500 MB of
   * contiguous heap, and the failure mode is an out-of-memory kill, not a catchable
   * error. This writes each received chunk to disk as it arrives, so peak memory is
   * one chunk.
   *
   * The status code only becomes available when `requestInStream` settles, which is
   * after the body has been written. That is acceptable because the caller writes to
   * a temporary path and promotes it only on success — so an error page lands in a
   * file that is then deleted, never at the destination.
   *
   * `onProgress` receives `(received, total)` where `total` is -1 when the server
   * sent no `Content-Length`.
   */
  async getToFile(
    url: string,
    headers: Map<string, string>,
    destPath: string,
    timeoutMs: number,
    onProgress?: (received: number, total: number) => void,
  ): Promise<number> {
    const request: http.HttpRequest = http.createHttp();

    let status: number = 0;
    let received: number = 0;
    let total: number = -1;
    let writeFailure: string = '';
    let file: fileIo.File | undefined = undefined;

    try {
      file = await fileIo.open(
        destPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );
    } catch (err) {
      request.destroy();
      // A **local** failure, and classified as one. The open creates a file inside this
      // app's own sandbox, so the causes are a missing parent directory, a permission
      // refusal, a full disk — none of them reachable by retrying the request, and none of
      // them on the network. `classifyError` would have labelled it `NETWORK`, because for
      // any error that is not already an `InkBoatError` that helper's only sensible default
      // is the transport. That default is right for a request and wrong here: it sent the
      // diagnosis of a fresh-install download failure down the WebDAV path when the open
      // had never left the device.
      const detail: string = err instanceof Error ? err.message : JSON.stringify(err);
      throw new InkBoatError(
        SyncErrorKind.FILE,
        `无法创建下载文件 ${destPath} 失败：${detail}`,
      );
    }
    const handle: fileIo.File = file;

    /**
     * Write one chunk.
     *
     * Deliberately synchronous: the event emitter does not await an async handler,
     * so an async one would let chunks overlap and interleave their writes. The body
     * is not reorderable once written.
     */
    const onChunk = (chunk: ArrayBuffer): void => {
      if (writeFailure.length > 0) {
        return;
      }
      try {
        fileIo.writeSync(handle.fd, chunk);
        received += chunk.byteLength;
        if (onProgress !== undefined) {
          onProgress(received, total);
        }
      } catch (err) {
        writeFailure = err instanceof Error ? err.message : JSON.stringify(err);
      }
    };

    const onHeaders = (header: Object): void => {
      const lengthHeader: string | undefined = this.headerValue(header, 'content-length');
      if (lengthHeader !== undefined) {
        const parsed: number = Number.parseInt(lengthHeader, 10);
        if (!Number.isNaN(parsed) && parsed >= 0) {
          total = parsed;
        }
      }
    };

    try {
      request.on('headersReceive', onHeaders);
      request.on('dataReceive', onChunk);

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: mapToRecord(headers),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        // The framework's own ceiling for a streamed response. Documented as 50 MB
        // unless `maxLimit` is raised, and 100 MB is the maximum it accepts.
        maxLimit: MAX_RESPONSE_BYTES,
      };

      // `requestInStream` resolves with the status code once the whole body has been
      // delivered, so it — not `dataEnd` — is what this waits on. `dataEnd` is
      // handled only to satisfy the emitter contract.
      request.on('dataEnd', (): void => {});
      const streamed: Promise<number> = request.requestInStream(url, options);

      status = await this.withStreamTimeout(streamed, timeoutMs, url);
      if (status === HTTP_TIMEOUT_SENTINEL) {
        throw new Error(`GET ${url} timeout after ${timeoutMs}ms`);
      }
    } catch (err) {
      await this.closeQuietly(handle);
      throw err instanceof InkBoatError
        ? classifyError(err, 'WebDAV 下载失败')
        : this.fromTransportError(err, 'GET', url);
    }

    await this.closeQuietly(handle);

    if (writeFailure.length > 0) {
      throw new InkBoatError(SyncErrorKind.FILE, `写入下载文件失败：${writeFailure}`);
    }
    if (!isSuccessStatus(status)) {
      throw new InkBoatError(kindFromStatus(status), `下载失败：HTTP ${status}`, status);
    }
    return received;
  }

  /** Bound a streaming transfer in wall-clock time. */
  private async withStreamTimeout(
    work: Promise<number>,
    timeoutMs: number,
    url: string,
  ): Promise<number> {
    let timer: number = -1;
    const timeout: Promise<number> = new Promise(
      (resolve: (value: number) => void): void => {
        timer = setTimeout((): void => {
          // A sentinel rather than a rejection, so a transfer that completes just
          // after the timer fires still wins the race.
          resolve(HTTP_TIMEOUT_SENTINEL);
        }, timeoutMs);
      },
    );
    try {
      return await Promise.race([work, timeout]);
    } finally {
      if (timer !== -1) {
        clearTimeout(timer);
      }
    }
  }

  private async closeQuietly(file: fileIo.File): Promise<void> {
    try {
      await fileIo.close(file);
    } catch (err) {
      // A failed close must not mask the transfer's own outcome.
    }
  }
}

/** Map a WebDAV method onto the closest legal `RequestMethod` for the base verb. */
/**
 * Success test for the transport layer.
 *
 * Duplicated from `WebDavClient.isSuccess` because the transport cannot reach that
 * method. 207 is included: a multi-status answer is a legitimate PROPFIND result and
 * some servers return it for GET on a collection.
 */
function isSuccessStatus(status: number): boolean {
  return (status >= 200 && status < 300) || status === 207;
}

/** Turn a header map into the plain object `@ohos.net.http` expects. */
function mapToRecord(headers: Map<string, string>): Record<string, string> {
  const record: Record<string, string> = {};
  headers.forEach((value: string, key: string): void => {
    record[key] = value;
  });
  return record;
}

/**
 * The `RequestMethod` for a verb, or `undefined` when the verb is not an HTTP method.
 *
 * WebDAV extensions have no `RequestMethod` member, and the official Network Kit
 * WebDAV example never sets `method` for them — it passes `customMethod` alone. The
 * SDK documents `customMethod` as taking priority over `method`, so setting a
 * carrier verb is at best redundant; leaving it out also avoids POST's implicit
 * `Content-Type: application/json` default being applied to a `PROPFIND`.
 *
 * Returning `undefined` rather than a fallback is the point: there is no correct
 * carrier verb, so the caller omits the field.
 */
function baseMethodFor(method: string): http.RequestMethod | undefined {
  switch (method) {
    case 'GET':
      return http.RequestMethod.GET;
    case 'HEAD':
      return http.RequestMethod.HEAD;
    case 'PUT':
      return http.RequestMethod.PUT;
    case 'DELETE':
      return http.RequestMethod.DELETE;
    case 'OPTIONS':
      return http.RequestMethod.OPTIONS;
    case 'PATCH':
      return http.RequestMethod.PATCH;
    default:
      return undefined;
  }
}

/**
 * Build request options with `method` set only when it is a real HTTP method.
 *
 * Written out rather than built by assignment because ArkTS has no object spread,
 * and `method: undefined` is not the same as omitting the field — the latter leaves
 * the framework's GET default in place, which is what the official example relies on.
 */
function buildOptions(
  method: string,
  header: Record<string, string>,
  body: string | ArrayBuffer | undefined,
  timeoutMs: number,
  wantBytes: boolean,
): http.HttpRequestOptions {
  const base: http.RequestMethod | undefined = baseMethodFor(method);
  if (base === undefined) {
    return {
      customMethod: method,
      header: header,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      maxLimit: MAX_RESPONSE_BYTES,
      expectDataType: wantBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      extraData: body,
    };
  }
  return {
    method: base,
    customMethod: method,
    header: header,
    connectTimeout: timeoutMs,
    readTimeout: timeoutMs,
    maxLimit: MAX_RESPONSE_BYTES,
    expectDataType: wantBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
    extraData: body,
  };
}

export class WebDavClient {
  private readonly baseUrl: string;
  private readonly authHeader: string;
  private readonly transport: HttpTransport;
  private readonly knownCollections: Set<string> = new Set<string>();
  private hadAuthSuccess: boolean = false;

  constructor(
    config: WebDavConfig,
    password: string,
    transport?: HttpTransport,
  ) {
    this.baseUrl = sanitizeWebDavUrl(config.url);
    // UTF-8 basic auth. `btoa` corrupts non-ASCII credentials, which is exactly
    // what a Chinese WebDAV provider with an app password hands you.
    const credentials: string = `${config.username}:${password}`;
    const encoded: string = new util.Base64Helper().encodeToStringSync(
      new util.TextEncoder().encodeInto(credentials),
    );
    this.authHeader = `Basic ${encoded}`;
    this.transport = transport ?? new HarmonyHttpTransport(config.allowInsecure);
  }

  private timeoutFor(method: string, explicit?: number): number {
    if (explicit !== undefined) {
      return explicit;
    }
    const isTransfer: boolean = method === 'PUT' || method === 'GET';
    return isTransfer ? TRANSFER_TIMEOUT_MS : DEFAULT_TIMEOUT_MS;
  }

  private baseHeaders(): Map<string, string> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Authorization', this.authHeader);
    return headers;
  }

  private isTransientStatus(status: number): boolean {
    // A 401 seen only after a successful authenticated response means the server
    // is throttling valid credentials under burst load (Jianguoyun and several
    // NAS products do this). A 401 before any success is a real auth failure.
    if (status === 401 && this.hadAuthSuccess) {
      return true;
    }
    if (status === 429) {
      return true;
    }
    return status >= 500 && status < 600;
  }

  private async request(
    method: string,
    path: string,
    body: string | ArrayBuffer | undefined,
    extraHeaders: Map<string, string> | undefined,
    timeoutMs: number | undefined,
    wantBytes: boolean,
  ): Promise<DavResponse> {
    const url: string = buildRequestUrl(this.baseUrl, path);
    const effectiveTimeout: number = this.timeoutFor(method, timeoutMs);

    for (let attempt = 0; ; attempt++) {
      const headers: Map<string, string> = this.baseHeaders();
      if (extraHeaders !== undefined) {
        extraHeaders.forEach((value: string, key: string): void => {
          headers.set(key, value);
        });
      }

      const response: DavResponse = await this.transport.send(
        method,
        url,
        headers,
        body,
        effectiveTimeout,
        wantBytes,
      );

      if (this.isSuccess(response.status)) {
        this.hadAuthSuccess = true;
        return response;
      }

      if (attempt < RETRY_MAX_ATTEMPTS && this.isTransientStatus(response.status)) {
        await delay(RETRY_BASE_DELAY_MS * Math.pow(2, attempt));
        continue;
      }

      throw new InkBoatError(
        kindFromStatus(response.status),
        `${method} ${path} 返回 ${response.status}${response.statusText.length > 0 ? ` ${response.statusText}` : ''}`,
        response.status,
        method,
        url,
      );
    }
  }

  /** 2xx and 207 both mean success; some servers answer 207 to plain GET. */
  private isSuccess(status: number): boolean {
    return (status >= 200 && status < 300) || status === 207;
  }

  /** Probe the server and validate credentials. */
  async ping(path: string = '/'): Promise<void> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Depth', '0');
    headers.set('Content-Type', 'application/xml');
    await this.request('PROPFIND', path, PROPFIND_RESOURCETYPE_BODY, headers, PING_TIMEOUT_MS, false);
  }

  async testConnection(): Promise<boolean> {
    await this.ping();
    return true;
  }

  /**
   * `PROPFIND Depth: 1`, returning only direct children of a **collection**.
   *
   * The path is normalized to its trailing-slash form before the request goes out,
   * and that is a correctness requirement rather than cosmetics. `PROPFIND` is
   * only one of the WebDAV extension verbs when this client sends it; on the wire
   * it is a request the client library would re-issue as a plain `GET` if it ever
   * followed a redirect. A collection addressed without its trailing slash gets a
   * `301` from Apache's `mod_dir` (and equivalents on nginx / Synology), so the
   * body that comes back is a directory index or an empty document rather than a
   * `207` multistatus — a listing that "succeeded" and parses to zero entries.
   *
   * The reference client does exactly this and only does it here: its `propfind`
   * passes the path through untouched and its `safeReadDir` — the one listing
   * entry point — wraps it in `toCollectionPath` first (`webdav-client.ts:717-720`
   * at tag `v1.3.6`). This method is the equivalent single entry point, so the
   * normalization belongs here and nowhere else. All four callers
   * (`safeListDir`, `parentListingContainsCollection`, `V1FilePhase.scanRemoteBooks`
   * and `FileStorageRunner.indexRemoteFolders` / `hasCoverInFolder`) pass a
   * collection.
   *
   * A **file** must never come through here. `exists()` probes a file through
   * `probeWithPropfind`, which is a `Depth: 0` request issued on the path as
   * given — appending a slash there would address a non-existent collection and
   * turn "present" into "absent". `toCollectionRequestPath` is idempotent, so a
   * caller that has already normalized cannot produce a doubled slash.
   */
  async listDir(path: string): Promise<RemoteResource[]> {
    const collectionPath: string = toCollectionRequestPath(path);
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Depth', '1');
    headers.set('Content-Type', 'application/xml');
    const response: DavResponse = await this.request(
      'PROPFIND',
      collectionPath,
      PROPFIND_LISTING_BODY,
      headers,
      undefined,
      false,
    );
    const url: string = buildRequestUrl(this.baseUrl, collectionPath);
    const parsed: ParsedListing = parsePropfindDetailed(
      response.body,
      normalizeWebDavPath(collectionPath),
      url,
    );
    const resources: RemoteResource[] = parsed.resources;
    if (resources.length > 0) {
      hilog.info(DOMAIN, TAG,
        'PROPFIND Depth:1 %{public}s -> HTTP %{public}d, %{public}d of %{public}d response block(s) are direct children%s',
        collectionPath, response.status, resources.length, parsed.report.blocks,
        parsed.report.usedFallback ? ', matched via the logical-path fallback' : '');
      return resources;
    }

    // The state this exists to make impossible to hit blindly again. A listing that
    // yields nothing is either a genuinely empty collection or a body this parser could
    // not read, and the two are indistinguishable from an entry count alone. The block
    // and href counts separate them: a real `multistatus` that lists only the collection
    // itself has blocks > 0, while a directory index, an error page, an unparsed binary
    // or an empty document has blocks = 0. The body's first characters settle the rest,
    // and they are logged either way so the next device run needs no second attempt.
    if (parsed.report.blocks === 0) {
      hilog.warn(DOMAIN, TAG,
        'PROPFIND Depth:1 %{public}s returned HTTP %{public}d but NO <response> block; %{public}d chars, body begins: %{public}s',
        collectionPath, response.status, response.body.length, bodyExcerpt(response.body));
    } else {
      hilog.warn(DOMAIN, TAG,
        'PROPFIND Depth:1 %{public}s returned HTTP %{public}d with %{public}d block(s) / %{public}d href(s) but none is a direct child of %{public}s (fallback base %{public}s, used %{public}s); body begins: %{public}s',
        collectionPath, response.status, parsed.report.blocks, parsed.report.hrefs,
        parsed.report.strictBasePath, parsed.report.fallbackBasePath,
        parsed.report.usedFallback ? 'yes' : 'no', bodyExcerpt(response.body));
    }
    return resources;
  }

  /**
   * Listing that treats an absent collection as empty.
   *
   * Every caller of this today is enumerating an optional remote folder, and a
   * missing folder is the normal first-run state, not an error.
   */
  async safeListDir(path: string): Promise<RemoteResource[]> {
    try {
      return await this.listDir(path);
    } catch (err) {
      if (err instanceof InkBoatError && err.kind === SyncErrorKind.NOT_FOUND) {
        return [];
      }
      throw classifyError(err, 'WebDAV 请求失败');
    }
  }

  /** Existence check. HEAD first, falling back to PROPFIND when HEAD is refused. */
  /**
   * True when the path exists.
   *
   * `HEAD` first because it is the cheapest answer, then `PROPFIND Depth: 0` when the
   * server refuses `HEAD` with 405 — which is common, since `HEAD` is optional and
   * some WebDAV implementations omit it.
   *
   * Any other failure is reported as "does not exist" rather than thrown. This is a
   * probe, not an operation: its callers use it to decide whether to create something,
   * and a network blip during a probe should lead to an attempt, not to an exception
   * that aborts a whole directory-creation pass. The reference implementation takes
   * the same view.
   */
  async exists(path: string): Promise<boolean> {
    try {
      await this.request('HEAD', path, undefined, undefined, DIRECTORY_PROBE_TIMEOUT_MS, false);
      return true;
    } catch (err) {
      if (err instanceof InkBoatError && err.kind === SyncErrorKind.METHOD_NOT_ALLOWED) {
        try {
          return await this.probeWithPropfind(path);
        } catch (propfindErr) {
          return false;
        }
      }
      return false;
    }
  }

  /**
   * Ask the server whether a path exists, with `PROPFIND Depth: 0`.
   *
   * Returns `false` for every answer that is not a positive one, including a refusal.
   * This is one of two probing strategies, and a refusal says only that *this* method
   * could not get an answer — not that anything is wrong. Throwing instead would skip
   * the parent-listing fallback that exists precisely for servers which refuse a
   * direct probe, so the failure mode would be the one the fallback was added to fix.
   *
   * Only a `207 Multi-Status` or a plain 2xx counts as present; a `200` with an empty
   * body is not something this method can distinguish, and the caller's next step
   * (`MKCOL`, whose "already exists" answer is 405) is safe either way.
   */
  private async probeWithPropfind(path: string): Promise<boolean> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Depth', '0');
    headers.set('Content-Type', 'application/xml');
    try {
      await this.request(
        'PROPFIND',
        path,
        PROPFIND_RESOURCETYPE_BODY,
        headers,
        DIRECTORY_PROBE_TIMEOUT_MS,
        false,
      );
      return true;
    } catch (err) {
      if (err instanceof InkBoatError) {
        // 404/410 absent; 403/401/405 refused; 405/501 unsupported. All mean "not
        // answered", which is what `false` reports here.
        return false;
      }
      return false;
    }
  }

  /**
   * True when the collection exists (used to make MKCOL idempotent).
   *
   * Two strategies, because neither works everywhere. A `PROPFIND Depth: 0` on the
   * collection itself is the direct answer, but some NAS products and WebDAV gateways
   * refuse it — 403 when the path is not known to them, or an outright block on
   * `PROPFIND` for certain prefixes. When that happens, listing the *parent* and
   * looking for a child of the same name gives the same answer through a request the
   * server does allow.
   *
   * The fallback is what makes `ensureDirectory` usable on those servers: without it a
   * refused probe reads as "cannot create the directory", and every upload into a new
   * book folder fails.
   */
  async collectionExists(path: string): Promise<boolean> {
    const collectionPath: string = toCollectionPath(path);
    try {
      if (await this.probeWithPropfind(collectionPath)) {
        return true;
      }
    } catch (err) {
      // Fall through to the listing strategy rather than propagating: a probe the
      // server refuses says nothing about whether the collection exists.
      //
      // Logged because this is evidence *about the server*: a refusal here means the
      // host does not answer a direct `PROPFIND` on a collection, which is a property
      // worth knowing when diagnosing a sync that behaves differently against one NAS
      // than another. It is not an error — the fallback is expected to succeed.
      hilog.info(DOMAIN, TAG, 'collectionExists probe refused, falling back to listing: %{public}s',
        String(err));
    }
    return await this.parentListingContainsCollection(collectionPath);
  }

  /**
   * Look for a collection by listing its parent.
   *
   * `parentOf` yields the parent and the last segment; a top-level collection has no
   * parent to list, and in that case the collection's existence cannot be established
   * this way — reported as `true` so the caller does not attempt a redundant MKCOL at
   * the root, where it would fail with a confusing error.
   */
  private async parentListingContainsCollection(collectionPath: string): Promise<boolean> {
    const parent: string = parentOf(collectionPath);
    if (parent === collectionPath || parent.length === 0) {
      return true;
    }
    const name: string = filenameFromPath(collectionPath);
    if (name.length === 0) {
      return true;
    }
    try {
      const entries: RemoteResource[] = await this.listDir(parent);
      for (const entry of entries) {
        if (entry.name === name) {
          return true;
        }
      }
      return false;
    } catch (err) {
      // The parent cannot be listed either, so the question stays unanswered. `false`
      // is the safe answer: it leads to a `MKCOL`, and a `MKCOL` on an existing
      // collection answers 405, which `ensureDirectory` already treats as success.
      //
      // Debug rather than warn: an inconclusive probe is an expected path, and the
      // `MKCOL` that follows either succeeds or reports 405-as-success. Logged anyway,
      // because "neither strategy worked" is the state that explains a directory pass
      // that keeps re-creating collections.
      hilog.debug(DOMAIN, TAG, 'collection probe inconclusive for %{public}s: %{public}s',
        collectionPath, String(err));
      return false;
    }
  }

  /**
   * Create a collection, including all missing ancestors.
   *
   * `MKCOL` is only valid on the immediate parent's child, so a nested path like
   * `/readany/data/books` needs `/readany` and `/readany/data` created first.
   * A 405 means "already exists", which is success for our purposes.
   */
  async ensureDirectory(path: string): Promise<void> {
    const collectionPath: string = toCollectionPath(path);
    if (this.knownCollections.has(collectionPath)) {
      return;
    }

    const segments: string[] = collectionPath.split('/');
    let current: string = '';
    for (let i = 0; i < segments.length; i++) {
      const segment: string = segments[i];
      if (segment.length === 0) {
        continue;
      }
      current = `${current}/${segment}`;
      const parent: string = toCollectionPath(current);
      if (this.knownCollections.has(parent)) {
        continue;
      }

      let created: boolean = false;
      try {
        await this.request('MKCOL', parent, undefined, undefined, undefined, false);
        created = true;
      } catch (err) {
        created = await this.recoverMkcol(parent, current, err as Object);
      }
      if (created) {
        this.knownCollections.add(parent);
        continue;
      }
      throw new InkBoatError(
        SyncErrorKind.FORBIDDEN,
        `无法创建远程目录 ${current}`,
      );
    }
  }

  /**
   * Decide whether a failed `MKCOL` actually means the collection is unusable.
   *
   * A failure here is not automatically fatal, because several real servers answer
   * something other than 201 for a collection they already have:
   *
   *  - **405** — RFC 4918's "already exists", which is success for this purpose.
   *  - **401 / 403 on a collection that exists** — some NAS products and gateways
   *    refuse `MKCOL` on paths they consider protected even when the path is already
   *    there. Throwing here would abort the whole directory pass on a server where
   *    nothing is actually wrong.
   *  - **409** — RFC 4918's "intermediate collection missing", but also what some
   *    servers answer when they mishandle the trailing slash. Both are recovered by
   *    re-issuing the chain without the slash.
   *
   * Returns true when the collection is usable afterwards.
   */
  private async recoverMkcol(
    collectionPath: string,
    plainPath: string,
    cause: Object,
  ): Promise<boolean> {
    if (cause instanceof InkBoatError && cause.kind === SyncErrorKind.METHOD_NOT_ALLOWED) {
      return true;
    }

    // Probe before blaming the credentials: for 401/403 the answer decides whether
    // this is an error at all.
    let present: boolean = false;
    try {
      present = await this.collectionExists(collectionPath);
    } catch (probeErr) {
      present = false;
    }
    if (present) {
      return true;
    }

    // 409 and 404 are the shapes a missing intermediate takes. Some servers also
    // reject the trailing slash on `MKCOL` itself, so the retry drops it.
    const status: number = cause instanceof InkBoatError ? cause.status : 0;
    const retriable: boolean = status === 409 || status === 404 || status === 0;
    if (!retriable) {
      return false;
    }
    try {
      await this.request('MKCOL', plainPath, undefined, undefined, undefined, false);
      return true;
    } catch (retryErr) {
      if (retryErr instanceof InkBoatError
        && retryErr.kind === SyncErrorKind.METHOD_NOT_ALLOWED) {
        return true;
      }
      // The retry failed too; fall back to one more probe, since a server that
      // answered an error to both spellings may still have the collection.
      try {
        return await this.collectionExists(collectionPath);
      } catch (probeErr) {
        return false;
      }
    }
  }

  /** Download a text document (JSON index, per-book files). */
  async getText(path: string): Promise<string> {
    const response: DavResponse = await this.request('GET', path, undefined, undefined, undefined, false);
    return response.body;
  }

  /** Download raw bytes (book files, covers). */
  async getBytes(path: string): Promise<Uint8Array> {
    const response: DavResponse = await this.request('GET', path, undefined, undefined, undefined, true);
    return response.bytes;
  }

  /**
   * Upload text.
   *
   * Self-heals a missing parent: Synology, QNAP and 飞牛 answer 403/404/409 when
   * PUT targets a folder that does not exist yet, and the first upload into a
   * brand-new book folder reliably hits that path.
   */
  async putText(path: string, text: string, contentType: string): Promise<void> {
    await this.putWithDirectoryHeal(path, contentType, text);
  }

  async putBytes(path: string, data: Uint8Array, contentType: string): Promise<void> {
    await this.putWithDirectoryHeal(path, contentType, data.buffer as ArrayBuffer);
  }

  /**
   * Download a file to disk without buffering it.
   *
   * The counterpart to `getBytes` for anything that could be large. Retries are not
   * applied here: `request` retries transient statuses, but a streaming transfer has
   * already written bytes to the destination by the time a status is known, and
   * restarting it mid-file is the caller's decision — it owns the temporary path and
   * deletes it on failure.
   */
  async getToFile(
    path: string,
    destPath: string,
    timeoutMs: number,
    onProgress?: (received: number, total: number) => void,
  ): Promise<number> {
    const url: string = buildRequestUrl(this.baseUrl, path);
    try {
      return await this.transport.getToFile(
        url,
        this.baseHeaders(),
        destPath,
        timeoutMs,
        onProgress,
      );
    } catch (err) {
      throw classifyError(err, 'WebDAV 下载失败');
    }
  }


  private async putWithDirectoryHeal(
    path: string,
    contentType: string,
    body: string | ArrayBuffer,
  ): Promise<void> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Content-Type', contentType);
    try {
      await this.request('PUT', path, body, headers, undefined, false);
    } catch (err) {
      if (!(err instanceof InkBoatError)) {
        throw classifyError(err, 'WebDAV 请求失败');
      }
      const healable: boolean =
        err.status === 403 || err.status === 404 || err.status === 409;
      if (!healable) {
        throw classifyError(err, 'WebDAV 请求失败');
      }
      const parent: string = parentOf(path);
      if (parent.length === 0 || parent === '/') {
        throw classifyError(err, 'WebDAV 请求失败');
      }
      await this.ensureDirectory(parent);
      await this.request('PUT', path, body, headers, undefined, false);
    }
  }

  /** Delete. A 404 means the goal state is already reached. */
  async deletePath(path: string): Promise<void> {
    try {
      await this.request('DELETE', path, undefined, undefined, undefined, false);
    } catch (err) {
      if (err instanceof InkBoatError && err.kind === SyncErrorKind.NOT_FOUND) {
        return;
      }
      throw classifyError(err, 'WebDAV 请求失败');
    }
  }

  /**
   * Move, refusing to overwrite.
   *
   * `Overwrite: F` makes the server answer 412 when the destination exists
   * instead of silently destroying whichever version lost the race. The caller
   * then resolves the conflict explicitly.
   */
  async move(fromPath: string, toPath: string): Promise<void> {
    const destination: string = buildRequestUrl(this.baseUrl, toPath);
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Destination', destination);
    headers.set('Overwrite', 'F');
    await this.request('MOVE', fromPath, undefined, headers, undefined, false);
  }

  dispose(): void {
    this.knownCollections.clear();
  }
}

/**
 * Coerce a caught value into an `InkBoatError`.
 *
 * ArkTS forbids `throw` with a value of a non-Error type and forbids type
 * annotations in a `catch` clause, so a rethrow has to be re-wrapped rather than
 * forwarded. An already-classified error is returned unchanged so its `kind` and
 * HTTP status survive.
 */
function classifyError(cause: Object | undefined, fallback: string): InkBoatError {
  if (cause instanceof InkBoatError) {
    return cause;
  }
  if (cause instanceof Error) {
    return new InkBoatError(SyncErrorKind.NETWORK, cause.message, 0, '', '');
  }
  return new InkBoatError(SyncErrorKind.UNKNOWN, fallback, 0, '', '');
}

/** Parent logical path, or `/` at the root. */
export function parentOf(path: string): string {
  const trimmed: string = path.replace(/\/+$/, '');
  const cut: number = trimmed.lastIndexOf('/');
  if (cut <= 0) {
    return '/';
  }
  return trimmed.substring(0, cut);
}

/**
 * The first `BODY_EXCERPT_LENGTH` characters of a response body, with control
 * characters and runs of whitespace collapsed to single spaces.
 *
 * A raw body would put newlines into a `hilog` line and split one diagnostic
 * across several, which is exactly how a log becomes unreadable at the moment it
 * matters. XML indentation carries no information here, so collapsing it costs
 * nothing and makes the line greppable.
 *
 * An empty body reports `<empty>` rather than an empty string: "the server sent
 * nothing" and "the log line was truncated" must not print the same way.
 */
function bodyExcerpt(body: string): string {
  if (body.length === 0) {
    return '<empty>';
  }
  const flattened: string = body
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const head: string = flattened.length > BODY_EXCERPT_LENGTH
    ? flattened.substring(0, BODY_EXCERPT_LENGTH)
    : flattened;
  const suffix: string = flattened.length > BODY_EXCERPT_LENGTH ? '…' : '';
  return head.length > 0 ? `${head}${suffix}` : '<whitespace only>';
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}
