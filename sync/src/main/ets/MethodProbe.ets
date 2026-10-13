/**
 * Network method probe.
 *
 * Exists to answer one question on a real device without any WebDAV credentials:
 * **does `customMethod` actually put a non-standard verb on the wire?**
 *
 * This is the single largest unverified assumption in the project. The SDK documents
 * `customMethod` as taking priority over `method` and names WebDAV in its comment, but
 * that is documentation, not evidence, and every WebDAV request the app makes —
 * `PROPFIND`, `MKCOL`, `MOVE` — depends on it. Failing this late would invalidate the
 * transport layer.
 *
 * ## Why the status code alone is not enough
 *
 * An earlier version of this probe judged success from the status code: any response
 * meant the verb arrived, and 405/501 was called "the cleanest evidence".
 *
 * That reasoning has a hole. If `customMethod` is **silently ignored** and a default
 * verb such as `GET` goes out instead, the server still answers — and the probe would
 * report success while the app is broken. Worse, on a real WebDAV endpoint the two
 * cases invert: a server that only accepts `PROPFIND` answers `405` to a `GET`, so a
 * `405` is what a *broken* `customMethod` looks like, not what a working one does.
 *
 * ## What actually counts as evidence
 *
 * The reflected request. `httpbin.org/anything` echoes the method it received in its
 * JSON body, so the probe reads that field back and compares it with what was sent.
 * A match is proof; a mismatch is proof of the opposite and names the verb that was
 * substituted.
 *
 * The status code is still reported, because it is the second-best signal and the only
 * one available against a server that does not echo.
 *
 * Deliberately credential-free: a probe that needed the user to set up a WebDAV
 * account first would not get run.
 */

import { http } from '@kit.NetworkKit';

/**
 * A host guaranteed to answer any method with a status.
 *
 * `httpbin.org` reflects the request, and its `405`/`501` on an unknown method is the
 * signal being looked for. A failure to reach the internet is itself reported
 * distinctly, so an offline device is not mistaken for a broken request stack.
 */
export const DEFAULT_PROBE_URL: string = 'https://httpbin.org/anything';

/** Outcome of one probe step. */
export interface ProbeStep {
  label: string;
  /** HTTP status, or 0 when no response arrived. */
  status: number;
  /** Round-trip in ms, or 0 when unmeasured. */
  elapsedMs: number;
  /** True when a response arrived at all, whatever its status. */
  reached: boolean;
  /** The verb the request asked for. */
  sentMethod: string;
  /**
   * The verb the server says it received, or an empty string when the host does not
   * reflect it. Non-empty here is the only direct evidence this probe can produce.
   */
  reflectedMethod: string;
  detail: string;
}

/** Outcome of the whole probe. */
export interface ProbeResult {
  /** Host reachability (the control step). */
  reachability: ProbeStep;
  /** Whether `customMethod` carried a non-standard verb. */
  customMethod: ProbeStep;
  /** Plain-language verdict. */
  verdict: string;
  /** True only when the verb demonstrably reached a server. */
  customMethodWorks: boolean;
}

const PROBE_TIMEOUT_MS: number = 15_000;

/**
 * Pull the method a reflector says it received out of a response body.
 *
 * `httpbin.org/anything` answers with `{"method": "PROPFIND", …}`. Anything without
 * that field — an HTML error page, a WebDAV `multistatus`, an empty body — yields an
 * empty string, which the verdict treats as "no direct evidence" rather than as
 * failure. A probe must not report a false negative just because the host stayed
 * silent about what it saw.
 */
export function reflectedMethodOf(body: string): string {
  const match: RegExpMatchArray | null = body.match(/"method"\s*:\s*"([A-Za-z]+)"/);
  if (match === null) {
    return '';
  }
  return (match[1] as string).toUpperCase();
}

/** Run one request and record what happened. */
async function sendProbe(
  label: string,
  url: string,
  method: string,
  useCustom: boolean,
): Promise<ProbeStep> {
  const request: http.HttpRequest = http.createHttp();
  const started: number = Date.now();
  try {
    const options: http.HttpRequestOptions = useCustom
      ? {
        // `method` deliberately omitted for the custom case; see `baseMethodFor` in
        // `WebDavClient` for why.
        customMethod: method,
        connectTimeout: PROBE_TIMEOUT_MS,
        readTimeout: PROBE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        header: { 'Content-Type': 'text/xml', 'Depth': '0' },
      }
      : {
        method: http.RequestMethod.GET,
        connectTimeout: PROBE_TIMEOUT_MS,
        readTimeout: PROBE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
      };

    const response: http.HttpResponse = await request.request(url, options);
    const status: number = response.responseCode as number;
    // The body is read only to look for a reflection; a large or binary body is not
    // a problem here because the probe targets a small JSON endpoint by default.
    const body: string = typeof response.result === 'string' ? response.result : '';
    const reflected: string = reflectedMethodOf(body);
    const elapsed: number = Date.now() - started;

    let detail: string = `HTTP ${status}，耗时 ${elapsed} ms`;
    if (reflected.length > 0) {
      detail += `，服务端收到的方法 = ${reflected}`;
    }
    if (method === 'GET' && elapsed > 0) {
      detail += `，本方发送 = GET`;
    } else if (useCustom) {
      detail += `，本方发送 = ${method}`;
    }

    return {
      label: label,
      status: status,
      elapsedMs: elapsed,
      // Any status is a reach: the server answered.
      reached: true,
      sentMethod: method,
      reflectedMethod: reflected,
      detail: detail,
    };
  } catch (err) {
    const message: string = err instanceof Error ? err.message : JSON.stringify(err);
    return {
      label: label,
      status: 0,
      elapsedMs: Date.now() - started,
      reached: false,
      sentMethod: method,
      reflectedMethod: '',
      detail: `${message}（耗时 ${Date.now() - started} ms）`,
    };
  } finally {
    request.destroy();
  }
}

/**
 * Run the probe against a URL.
 *
 * `url` should be any address the device can reach. The default is a public reflector
 * that echoes the request method; the user's own WebDAV root works too and exercises
 * the real server, but it will not reflect the verb, so the verdict falls back to the
 * status code.
 */
export async function probeCustomMethod(url: string = DEFAULT_PROBE_URL): Promise<ProbeResult> {
  const reachability: ProbeStep = await sendProbe('GET 可达性', url, 'GET', false);
  if (!reachability.reached) {
    return {
      reachability: reachability,
      customMethod: {
        label: 'PROPFIND',
        status: 0,
        elapsedMs: 0,
        reached: false,
        sentMethod: 'PROPFIND',
        reflectedMethod: '',
        detail: '未执行：主机不可达',
      },
      verdict: `主机不可达，无法判断 customMethod。请检查网络或换一个地址。\n(${reachability.detail})`,
      customMethodWorks: false,
    };
  }

  const customMethod: ProbeStep = await sendProbe('PROPFIND（customMethod）', url, 'PROPFIND', true);

  if (!customMethod.reached) {
    return {
      reachability: reachability,
      customMethod: customMethod,
      verdict: `GET 成功（HTTP ${reachability.status}）但 PROPFIND 未得到任何响应，`
        + `说明 customMethod 没能把方法发出去。同步功能需要改用 Web 组件内的 fetch 方案。\n`
        + `(${customMethod.detail})`,
      customMethodWorks: false,
    };
  }

  // ---- The decisive case: the host told us which verb it received ----------------
  const reflected: string = customMethod.reflectedMethod;
  if (reflected.length > 0) {
    if (reflected === 'PROPFIND') {
      return {
        reachability: reachability,
        customMethod: customMethod,
        verdict: `customMethod 已证实可用：服务端回显收到的方法是 PROPFIND，`
          + `与发送的方法一致。这是直接证据，不是推断。同步可以按当前实现继续。`,
        customMethodWorks: true,
      };
    }
    return {
      reachability: reachability,
      customMethod: customMethod,
      verdict: `customMethod 未生效：本方发送 PROPFIND，但服务端回显收到的是 ${reflected}。`
        + `说明该方法被忽略并替换成了其它动词——同步会静默失效。`
        + `需要改用 Web 组件内的 fetch 方案。`,
      customMethodWorks: false,
    };
  }

  // ---- No reflection: fall back to the status code, and say so -------------------
  //
  // `405` and `501` mean the server recognised a method it does not support, which is
  // consistent with the verb arriving — but it is **not proof**, because a GET against
  // a WebDAV-only collection also draws 405. A host that reflects removes the ambiguity;
  // one that does not leaves this as the best available signal.
  const refused: boolean = customMethod.status === 405 || customMethod.status === 501;
  const verdict: string = refused
    ? `customMethod 很可能可用：服务器以 HTTP ${customMethod.status} 拒绝了非标准方法，`
      + `这与「方法已到达并被拒绝」一致。\n`
      + `注意：该地址不回显收到的请求方法，所以这不是直接证据——只接受 PROPFIND 的 WebDAV 服务端`
      + `对 GET 也会回 405。要得到确定结论，请把探针地址换成会回显方法的地址`
      + `（默认的 httpbin.org/anything 就是）。`
    : `customMethod 得到了响应（HTTP ${customMethod.status}），说明请求发出了，`
      + `但该地址不回显收到的请求方法，无法据此断定动词是 PROPFIND 而不是被替换的默认动词。\n`
      + `要得到确定结论，请把探针地址换成会回显方法的地址。`;

  return {
    reachability: reachability,
    customMethod: customMethod,
    verdict: verdict,
    // Deliberately **not** true. A status without a reflection cannot distinguish a
    // working customMethod from an ignored one, and reporting success on that basis is
    // the exact false positive this version exists to remove.
    customMethodWorks: false,
  };
}

/** Render a probe result as lines for on-screen display. */
export function formatProbeResult(result: ProbeResult): string[] {
  const lines: string[] = [];
  lines.push(`· ${result.reachability.label}：${result.reachability.detail}`);
  lines.push(`· ${result.customMethod.label}：${result.customMethod.detail}`);
  lines.push(result.customMethodWorks ? '✓ customMethod 可用（已证实）' : '? 尚未证实 customMethod 可用');
  return lines;
}
