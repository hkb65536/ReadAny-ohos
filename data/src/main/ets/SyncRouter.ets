/**
 * Protocol routing between the two ReadAny sync dialects.
 *
 * `SyncEngine` speaks the per-book protocol (`{schemaVersion: 2, books, threads}` at
 * `/readany/sync/index.json`) and `SyncV1Engine` speaks the per-device snapshot protocol
 * (`{version: 1, updatedAt, devices}` at the *same path*). The two share a path and a
 * directory but not a version field, so the only thing that can say which one a server
 * speaks is the shape of the document that is actually there.
 *
 * ## Why a separate module
 *
 * Two reasons, and the second is the one that matters.
 *
 *  1. Reading the index is a *read*; deciding what to do about it is policy. Keeping the
 *     policy out of both engines means neither engine has to know the other exists, and
 *     the decision can be re-run — for the settings screen, and before an automatic pass
 *     — without constructing an engine.
 *  2. The decision is **fail-closed**, and that property is easier to see and to audit in
 *     one short function than spread across two engines' early guards.
 *
 * ## The table this implements
 *
 *     {version: 1, devices: {...}}      → v1
 *     {schemaVersion: 2, books, threads}→ v2
 *     absent (404, or an empty body)    → v1   (a fresh server: v1 is what the user's
 *                                               released desktop client writes)
 *     anything else                     → refuse: no write, remote untouched
 *
 * "Anything else" is taken seriously rather than treated as empty. A `{version: 2,
 * devices}` index from a future client, a `DeviceSyncPayload` body sitting at the index
 * path, a truncated or proxy-mangled body, a valid JSON object of an unknown shape —
 * every one of them is refused with the message that names what was found. Treating any
 * of them as "no index" and publishing this client's own view over it is how a client
 * destroys a library it merely failed to understand.
 *
 * The classifier itself is **not** reimplemented here: `classifyV1Index`,
 * `isWritableV1IndexKind` and `indexRefusalMessage` (all in `SyncV1.ets`) are the single
 * source of truth for the v1 side, and `classifyIndex`/`IndexKind` (in the sync layer)
 * for the v2 side. A second classifier would be a second thing to keep in step with the
 * wire format, and the failure mode of the two disagreeing is silent data loss.
 */

import { InkBoatError, SyncErrorKind } from 'core';
import { classifyIndex, IndexKind, SyncMode } from 'sync';
import {
  classifyV1Index,
  defaultV1SyncOptions,
  indexRefusalMessage,
  V1IndexKind,
} from './SyncV1';
import type { V1FileSyncCounts, V1IndexLoad, V1SyncOptions, V1SyncResult } from './SyncV1';

/** Which wire protocol a pass must speak. */
export enum SyncProtocol {
  /** The per-device snapshot protocol — ReadAny v1.3.6 and earlier. */
  V1 = 'v1',
  /** The per-book protocol — `schemaVersion: 2`. */
  V2 = 'v2',
  /**
   * The remote index is neither, or cannot be read as either. Nothing may be written.
   */
  REFUSED = 'refused',
}

/**
 * The routing decision, with the evidence behind it.
 *
 * A class rather than an interface: it is produced in this module and read by
 * `SyncService` and, through it, the settings screen, and ArkTS rejects an object literal
 * that implements an interface from another module (`arkts-no-untyped-obj-literals`,
 * see `docs/arkts-constraints.md` §2.0).
 */
export class ProtocolDecision {
  readonly protocol: SyncProtocol;
  /** The kind `classifyV1Index` reported, kept so the refusal text can be re-derived. */
  readonly kind: V1IndexKind;
  /** The message to show the user, non-empty only when `protocol` is `REFUSED`. */
  readonly refusal: string;

  constructor(protocol: SyncProtocol, kind: V1IndexKind, refusal: string) {
    this.protocol = protocol;
    this.kind = kind;
    this.refusal = refusal;
  }

  /** True when this decision forbids every write. */
  isRefused(): boolean {
    return this.protocol === SyncProtocol.REFUSED;
  }
}

/**
 * The protocol a v1 index classification implies.
 *
 * Note that `ABSENT` maps to **v1**, deliberately. A server with no `index.json` has no
 * per-book index either, and the released desktop client the user actually runs writes
 * the v1 document. Publishing a v2 index first would hide nothing (there is nothing
 * there) but it would make the desktop client — which reads this path — see a document it
 * does not understand, and it is the desktop's data that must survive.
 */
export function protocolForV1Kind(kind: V1IndexKind): SyncProtocol {
  if (kind === V1IndexKind.ABSENT || kind === V1IndexKind.INDEX_V1) {
    return SyncProtocol.V1;
  }
  if (kind === V1IndexKind.PER_BOOK_V2) {
    return SyncProtocol.V2;
  }
  return SyncProtocol.REFUSED;
}

/**
 * Decide the protocol from a loaded index.
 *
 * `loadIndex()` on `SyncV1Engine` produces the `V1IndexLoad` this takes, and it is the
 * only reader: it already keeps "absent" apart from "unparseable" through
 * `readJsonDocument`, which is what makes the `UNPARSEABLE` arm below reachable at all.
 *
 * Note what this function does **not** contain: any protocol literal. The v2 arm confirms
 * the v2 *shape* against the sync layer's own `classifyIndex` and then takes the protocol
 * from `protocolForV1Kind`, so the routing table exists in exactly one place. Writing
 * `SyncProtocol.V2` here as well would be a second copy of the table, and the two copies
 * disagreeing is precisely the class of defect this module was written to remove —
 * `tools/_mutate-sync-routing.mjs` found the earlier version of this code had exactly that
 * duplication.
 */
export function decideProtocol(index: V1IndexLoad): ProtocolDecision {
  const kind: V1IndexKind = index.kind;

  if (kind === V1IndexKind.PER_BOOK_V2) {
    if (classifyIndex(index.record) === IndexKind.PER_BOOK) {
      return new ProtocolDecision(protocolForV1Kind(kind), kind, '');
    }
    return new ProtocolDecision(
      SyncProtocol.REFUSED,
      kind,
      indexRefusalMessage(V1IndexKind.UNKNOWN, index.record),
    );
  }

  const protocol: SyncProtocol = protocolForV1Kind(kind);
  if (protocol === SyncProtocol.REFUSED) {
    return new ProtocolDecision(protocol, kind, indexRefusalMessage(kind, index.record));
  }
  return new ProtocolDecision(protocol, kind, '');
}

/**
 * The error a refusal is reported as.
 *
 * `UNSUPPORTED` rather than `NETWORK`: nothing failed to travel, this client simply
 * declined to write over a document it does not recognise, and the kind is what the
 * settings screen keys its wording off.
 */
export function protocolRefusalError(decision: ProtocolDecision): InkBoatError {
  return new InkBoatError(SyncErrorKind.UNSUPPORTED, decision.refusal);
}

/** A short label for the settings screen, naming the dialect and what it holds. */
export function describeProtocol(protocol: SyncProtocol): string {
  if (protocol === SyncProtocol.V1) {
    return 'v1（每设备快照，ReadAny 1.3.6）';
  }
  if (protocol === SyncProtocol.V2) {
    return 'v2（每书文件）';
  }
  return '已拒绝（索引形状无法识别）';
}

/**
 * The options a **user-triggered** v1 pass runs with.
 *
 * `forceApply` is `false`, and that is a hard rule rather than a default. In v1.3.6 the
 * flag disables **every** timestamp guard — `shouldApplyRemoteRecord` and the tombstone
 * comparison both — so a pass with it set would let an older remote row overwrite newer
 * local data, which is the exact opposite of what a normal sync is for. It exists for one
 * thing only: restoring a device from the server, which this client does not do over v1.
 *
 * `receiveOnly` is `false`: a user-triggered pass both pulls and publishes.
 *
 * The values come from `defaultV1SyncOptions()` rather than an object literal because
 * `V1SyncOptions` is declared in another module (§2.0); the explicit assignments below are
 * therefore not redundant — they are the assertion, in the place the pass is configured,
 * that a user-triggered pass never asks for a forced apply.
 *
 * ## Files
 *
 * The file flags come from the mode table too, but **not** through `policyForMode`: that
 * table's `FULL_DOWNLOAD` row is `forceApply: true`, which is exactly the thing the
 * paragraph above forbids. `v1FileOptionsForMode` therefore restates the file half of the
 * table with `forceApply` left alone, and `userInitiatedV1Options` starts from the engine
 * default so the flag cannot be set by anything but an explicit line.
 */
export function userInitiatedV1Options(): V1SyncOptions {
  const options: V1SyncOptions = defaultV1SyncOptions();
  options.receiveOnly = false;
  options.forceApply = false;
  // Files: a normal pass uploads what the server lacks and pulls missing covers, and
  // downloads no book file at all.
  options.forceUploadAll = false;
  options.forceDownloadAll = false;
  options.downloadRemoteBooks = false;
  options.disableUploads = false;
  return options;
}

/**
 * The v1 option set a given **mode** implies.
 *
 * The three modes are the user's own vocabulary — `同步` / `全量上传` / `全量下载` — and all
 * three must work on a v1 server now that files are in scope. They were refused outright
 * while the v1 path was metadata-only, because accepting `全量下载` and then syncing
 * nothing but metadata would have been a lie about what happened. With a file phase the
 * promise is real, so the refusal is gone and each mode maps onto the v1 flags:
 *
 *  - `NORMAL` — metadata both ways; files: upload a book the server lacks, pull a missing
 *    cover. **No book file is downloaded**: one tap on 同步 must not pull a library over
 *    cellular, which is the reference's behaviour (`sync-files.ts:372`) and the user's
 *    expectation.
 *  - `FULL_UPLOAD` — the same, plus `forceUploadAll`, so every local book file is re-sent.
 *    Uploads stay enabled and nothing is downloaded beyond a missing cover.
 *  - `FULL_DOWNLOAD` — `forceDownloadAll` plus `downloadRemoteBooks`, so every remote book
 *    file is fetched; `disableUploads` is set because the user asked to receive, and
 *    `receiveOnly` is set because the metadata half must not push either. Uploads being
 *    off leaves the manifest rewrite to the device that owns the files.
 *
 * `forceApply` is **never** set here — not even for `FULL_DOWNLOAD`, where
 * `policyForMode` sets it for the v2 path. The flag has no safe use on v1: it would disable
 * the timestamp comparison that protects newer local rows from an older remote snapshot,
 * and for `books` that is unrecoverable. `FULL_DOWNLOAD` therefore restores the files and
 * merges the metadata under the ordinary guards. That is a deliberate divergence from the
 * v2 policy table, and it is recorded here rather than left to be rediscovered.
 */
export function v1OptionsForMode(mode: SyncMode): V1SyncOptions {
  const options: V1SyncOptions = userInitiatedV1Options();
  if (mode === SyncMode.FULL_UPLOAD) {
    options.forceUploadAll = true;
    return options;
  }
  if (mode === SyncMode.FULL_DOWNLOAD) {
    options.forceDownloadAll = true;
    options.downloadRemoteBooks = true;
    options.disableUploads = true;
    options.receiveOnly = true;
    return options;
  }
  return options;
}

/**
 * One line describing a finished v1 pass.
 *
 * The file counters are reported when a file phase ran, and omitted when it did not: a
 * "文件上传 0" for a pass that had no file phase would be a true statement about a phase
 * that does not exist, which is information the user cannot act on.
 */
export function describeV1Result(result: V1SyncResult): string {
  const uploaded: string = result.uploaded
    ? `已上传本机快照（${result.counts.tablesUploaded} 张表）`
    : '本机快照未上传';
  const refused: string = result.counts.refusedDeletions > 0
    ? `，拒绝未证实删除 ${result.counts.refusedDeletions} 条`
    : '';
  const moved: string = describeV1Files(result.files);
  const error: string = result.error.length > 0 ? `；${result.error}` : '';
  return `v1 同步：应用 ${result.counts.applied} 条，跳过 ${result.counts.skipped} 条${refused}`
    + `，其他设备 ${result.appliedDevices.length} 台，${uploaded}${moved}${error}`;
}

/**
 * The file half of a v1 summary, or an empty string when no file phase ran.
 *
 * `manifestRefused` is named separately from the failures on purpose: nothing failed to
 * transfer in that case, the *document* could not be rewritten, and telling the user a file
 * transfer failed would send them looking in the wrong place.
 *
 * `firstFailure` is appended to the failure count rather than replacing it. The count says
 * how much did not move; the reason says why, and without it a line reading "失败 18" is
 * the whole report — which is exactly the state this was reported in. The reason is
 * truncated here because it can be an HTTP status line with a server-supplied body, and a
 * summary line is what the sync card shows; the untruncated text is in `hilog`.
 */
function describeV1Files(files: V1FileSyncCounts): string {
  const moved: number = files.filesUploaded + files.filesDownloaded + files.filesFailed;
  if (moved === 0 && !files.manifestRefused && files.phaseError.length === 0) {
    return '，文件已是最新';
  }
  const parts: string[] = [
    `文件上传 ${files.filesUploaded}，下载 ${files.filesDownloaded}`,
  ];
  if (files.filesFailed > 0) {
    const reason: string = summarizeReason(files.firstFailure);
    parts.push(reason.length > 0 ? `失败 ${files.filesFailed}（${reason}）` : `失败 ${files.filesFailed}`);
  }
  if (files.manifestRefused) {
    parts.push('清单未重写（远端清单无法解析）');
  }
  if (files.phaseError.length > 0) {
    // The phase stopped before it could finish, and the reason is worth more than the
    // counts: "文件上传 0" with no cause reads as "there was nothing to do".
    parts.push(`文件阶段中断：${files.phaseError}`);
  }
  return `，${parts.join('，')}`;
}

/** Longest failure reason the one-line summary quotes, before the log holds the rest. */
const SUMMARY_REASON_LIMIT: number = 120;

/**
 * One line's worth of a failure reason.
 *
 * Newlines are collapsed because a reason built from a transport error can carry the
 * server's own body, and a multi-line string would break the single summary line the sync
 * card renders around it.
 */
function summarizeReason(reason: string): string {
  const flat: string = reason.replace(/\s+/g, ' ').trim();
  if (flat.length <= SUMMARY_REASON_LIMIT) {
    return flat;
  }
  return `${flat.substring(0, SUMMARY_REASON_LIMIT)}…`;
}
