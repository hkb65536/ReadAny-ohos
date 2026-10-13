/**
 * Sync facade.
 *
 * Ties together the pieces that have to agree before a pass can run: the stored
 * configuration, the credential store, the network policy, and **whichever engine the
 * remote index says this server speaks**. The UI talks only to this class.
 *
 * ## Two engines, one entry point
 *
 * `SyncEngine` speaks the per-book protocol (`schemaVersion: 2`) and `SyncV1Engine` speaks
 * the per-device snapshot protocol that ReadAny v1.3.6 and earlier write. They share
 * `/readany/sync/index.json`, so the document's *shape* is the only thing that can say
 * which one applies — `SyncRouter` owns that decision, and it fails closed: an index it
 * cannot positively classify means nothing is written and the user is told what was found.
 *
 * The two dialects are not interchangeable in either direction. Publishing a v2 index over
 * a v1 one hides every device snapshot; applying a v1 payload with v2 rules would read a
 * peer's `deletedIds` as an overlay rather than as the destructive instruction it is.
 * Routing is therefore the first thing a pass does, before any write.
 *
 * A v1 pass is **metadata only**: its engine is constructed without a binary runner, so no
 * file is transferred and no remote-delete routine exists to be called. That is deliberate
 * and is explained on `ensureV1Engine`.
 *
 * The engine is rebuilt whenever the configuration changes. That is cheaper to
 * reason about than mutating a live engine, and it is what makes "test the
 * connection with these credentials before saving them" possible without
 * disturbing the configured client.
 */

import type { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InkBoatError, SyncErrorKind } from 'core';
import type { WebDavConfig } from 'sync';
// `SyncMode` is an enum, so it is a value and cannot travel in a `import type` list.
import {
  labelForMode,
  sanitizeWebDavRemoteRoot,
  sanitizeWebDavUrl,
  SyncMode,
  WebDavClient,
} from 'sync';
import { Bookmarks } from './Bookmarks';
import { BookGroups } from './BookGroups';
import { Books } from './Books';
import { CredentialStore } from './CredentialStore';
import type { Database } from './Database';
import { FileStorage } from './FileStorage';
import { hashFileSha256 } from './FileHasher';
import { FileStorageRunner } from './FileStorageRunner';
import { Highlights } from './Highlights';

import { isSyncAllowedNow } from './NetworkStatus';
import { Notes } from './Notes';
import { SyncConfigStore } from './SyncConfigStore';
import type { BookTransferCounts, SyncEngine, SyncProgress, SyncProgressFn } from './SyncEngine';
import {
  emptyTransferCounts,
  progressFromV1,
  SyncEngine as Engine,
} from './SyncEngine';
// Protocol routing. Both engines live in this module beside this facade; nothing outside
// `data` ever constructs either of them, which is what keeps the settings screen from
// having to know which protocol a server speaks.
import type { ProtocolDecision } from './SyncRouter';
import {
  decideProtocol,
  describeProtocol,
  describeV1Result,
  protocolRefusalError,
  SyncProtocol,
  v1OptionsForMode,
} from './SyncRouter';
import type { V1IndexLoad, V1Progress, V1SyncResult } from './SyncV1';
import { SyncV1Engine } from './SyncV1';
import { V1FilePhase } from './V1FilePhase';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatSync';

/**
 * How long progress updates are allowed to arrive before the UI is told, in ms.
 *
 * The engine reports per phase transition and per file; a download additionally reports its
 * bytes, throttled to ~8/s at the transfer layer (`FileStorageRunner`). Even after that,
 * emitting one snapshot per report would be a re-render per report, and a full download of
 * a large library is thousands of files. So this is the second, coarser gate: the newest
 * report is kept in a field and the observer is called at most about five times a second.
 *
 * The two gates are deliberately at different layers. The transfer layer's is about not
 * doing pointless work on the I/O path; this one is about not re-rendering on the UI path.
 * 200 ms is well under the ~300 ms at which a status line starts to look frozen, so nothing
 * is lost visually by waiting.
 */
const PROGRESS_EMIT_INTERVAL_MS: number = 200;

/** Where a sync pass currently is, for the UI. */
export enum SyncRunStatus {
  IDLE = 'idle',
  CHECKING = 'checking',
  RUNNING = 'running',
  SUCCESS = 'success',
  FAILED = 'failed',
}

/** What the UI renders. */
export interface SyncSnapshot {
  status: SyncRunStatus;
  /** True when URL, username and a stored password are all present. */
  configured: boolean;
  /** Progress line, empty when idle. */
  message: string;
  completed: number;
  total: number;
  lastSyncAt: number;
  lastError: string;
  lastCounts: BookTransferCounts;
  /**
   * File currently transferring, empty when none is.
   *
   * Carried on the snapshot as well as passed to the per-pass progress callback, so a
   * component that only subscribes (and never starts a pass itself) can still render the
   * live line. The file-transfer phase is the only one that fills it in.
   */
  currentFile: string;
  /** Bytes of `currentFile` so far; only ever non-zero for downloads. */
  fileBytesDone: number;
  /** `currentFile`'s total size, or 0 when the server did not say. */
  fileBytesTotal: number;
  /**
   * Which protocol the configured server speaks, as last decided.
   *
   * Carried on the snapshot because the user has to be able to tell: the two dialects keep
   * different things on the server, and "which one is my server speaking" is not something
   * the settings screen should have to ask the engine for separately.
   */
  protocol: SyncProtocol;
  /**
   * The summary line of the last **v1** pass, or empty.
   *
   * Empty after a v2 pass on purpose: that path's summary is built by the shell from
   * `lastCounts` and is unchanged, so nothing about the v2 report moves.
   */
  lastSummary: string;
}

/** Listener for snapshot changes. */
export type SyncObserver = (snapshot: SyncSnapshot) => void;

/** Per-pass progress listener, handed to `syncNow`. */
export type SyncProgressCallback = (progress: SyncProgress) => void;

export class SyncService {
  private readonly db: Database;
  private readonly configStore: SyncConfigStore;
  private readonly credentials: CredentialStore;
  /**
   * Local file storage, built lazily on first engine construction.
   *
   * Held rather than rebuilt per engine so the two `FileStorage` instances cannot
   * disagree about the sandbox root.
   */
  private readonly storage: FileStorage;

  private config: WebDavConfig;
  private configured: boolean = false;
  private status: SyncRunStatus = SyncRunStatus.IDLE;
  private message: string = '';
  private completed: number = 0;
  private total: number = 0;
  private lastError: string = '';
  private lastCounts: BookTransferCounts = emptyTransferCounts();

  /**
   * The newest progress report, when it has not been published yet.
   *
   * `undefined` means "nothing pending". Held as a field rather than passed straight
   * through so the coalescing below has something to coalesce *into*: the observer always
   * reads the latest value, never a queue of stale ones.
   */
  private pendingProgress: SyncProgress | undefined = undefined;
  /** Pending coalescing timer id, or -1 when none is armed. */
  private progressTimer: number = -1;
  /** When the observer was last told, for the interval test. */
  private lastEmitAt: number = 0;

  private engine: SyncEngine | undefined = undefined;
  /**
   * The v1 per-device engine, built lazily, **with** the v1 file phase.
   *
   * The file phase is `V1FilePhase`, not the v2 runner, and the difference is not
   * cosmetic. `V1FilePhase` implements the reference's `syncFiles` *minus* its three
   * destructive routines — `cleanupRemoteOrphans`, `cleanupLocalOrphans` and
   * `migrateBookRemoteState` — none of which exists in this client at all. ReadAny
   * v1.3.6's orphan cleanup deletes `/readany/data/books/{title}-{uuid}` folders whose id
   * is not in the local live set, so a client with an empty or partial library would
   * delete the user's books **from the server**. A routine that is absent cannot be
   * reached or mis-triggered, which is a stronger guarantee than a flag.
   */
  private v1Engine: SyncV1Engine | undefined = undefined;
  /**
   * True while the v1 pass is inside its file phase.
   *
   * The progress card's counter names its unit — 设备 for the v1 metadata pass, which
   * counts devices, and 文件 for its file phase, which counts transfers — and this is the
   * one bit that distinguishes them. Read from the pass itself rather than inferred from
   * the protocol, because both halves of a v1 pass speak the same protocol and count
   * different things.
   */
  private v1FilePhaseActive: boolean = false;
  /**
   * The transport, shared by both engines.
   *
   * Held here rather than inside each engine so a pass cannot transfer through a different
   * credential set than the one it read the index with, and so rebuilding one engine on a
   * configuration change does not leave the other pointing at the old server.
   */
  private client: WebDavClient | undefined = undefined;
  /** The protocol decided for the current configuration, `undefined` until asked. */
  private protocol: SyncProtocol | undefined = undefined;
  /** The message behind a `REFUSED` decision, empty otherwise. */
  private refusal: string = '';
  /** The last v1 pass's summary line; empty after a v2 pass. */
  private lastSummary: string = '';
  private running: boolean = false;
  private readonly observers: SyncObserver[] = [];

  private constructor(
    db: Database,
    configStore: SyncConfigStore,
    credentials: CredentialStore,
    config: WebDavConfig,
    storage: FileStorage,
  ) {
    this.db = db;
    this.configStore = configStore;
    this.credentials = credentials;
    this.config = config;
    this.storage = storage;
  }

  /**
   * Build the service.
   *
   * The credential probe is deliberately part of construction: the settings
   * screen must be able to tell "never configured" from "configured but the
   * device is locked", and only the credential store knows which.
   */
  static async create(
    context: common.UIAbilityContext,
    db: Database,
  ): Promise<SyncService> {
    const configStore: SyncConfigStore = await SyncConfigStore.open(context);
    const credentials: CredentialStore = new CredentialStore();
    const config: WebDavConfig = await configStore.load();
    // The sandbox root comes from the ability context, so `FileStorage` is built
    // here rather than in the engine — the engine has no business knowing how to
    // find the app's files directory.
    const storage: FileStorage = FileStorage.fromContext(context, hashFileSha256);
    const service: SyncService = new SyncService(db, configStore, credentials, config, storage);

    const hasDetails: boolean = config.url.length > 0 && config.username.length > 0;
    let hasPassword: boolean = false;
    try {
      hasPassword = hasDetails ? await credentials.hasWebDavPassword() : false;
    } catch (err) {
      // A locked device reports ACCESS_DENIED; `hasSecret` already maps that to
      // "present", so reaching here means a genuine store failure. Treat it as
      // not configured and let the next sync attempt surface the real error.
      hasPassword = false;
    }
    service.configured = hasDetails && hasPassword;
    return service;
  }

  /** Current state, for an initial render. */
  snapshot(): SyncSnapshot {
    return {
      status: this.status,
      configured: this.configured,
      message: this.message,
      completed: this.completed,
      total: this.total,
      lastSyncAt: 0,
      lastError: this.lastError,
      lastCounts: this.lastCounts,
      currentFile: this.pendingProgress === undefined ? '' : this.pendingProgress.currentFile,
      fileBytesDone: this.pendingProgress === undefined ? 0 : this.pendingProgress.fileBytesDone,
      fileBytesTotal: this.pendingProgress === undefined ? 0 : this.pendingProgress.fileBytesTotal,
      protocol: this.protocol ?? SyncProtocol.REFUSED,
      lastSummary: this.lastSummary,
    };
  }

  /** Subscribe to state changes. Returns an unsubscribe function. */
  observe(observer: SyncObserver): () => void {
    this.observers.push(observer);
    return (): void => {
      const index: number = this.observers.indexOf(observer);
      if (index >= 0) {
        this.observers.splice(index, 1);
      }
    };
  }

  private emit(): void {
    const current: SyncSnapshot = this.snapshot();
    for (const observer of this.observers.slice()) {
      try {
        observer(current);
      } catch (err) {
        // A misbehaving observer must not abort a sync pass — but it must not be
        // invisible either. A UI component that throws on every state update looks
        // like a sync that succeeds while the screen never changes, which is very
        // hard to attribute without a log line naming the failure.
        hilog.warn(DOMAIN, TAG, 'sync observer threw: %{public}s', String(err));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Progress: receiving it from the engine, publishing it without a render storm
  // ---------------------------------------------------------------------------

  /**
   * Take one progress report from the engine.
   *
   * The value is stored and the *latest* value is published on a timer, rather than each
   * report being published as it arrives. That matters because the reports are frequent: a
   * single book file reports per received chunk from the streaming reader, and a full
   * download reports once per chunk per file. Publishing each one would re-render the sync
   * page thousands of times for one pass, and every render would be thrown away by the next
   * report before anyone could read it.
   *
   * Three properties make the coalescing safe rather than merely cheap:
   *
   *  - the pending value is **replaced**, never queued, so what the UI shows is always the
   *    newest report and never a replay of stale ones;
   *  - a report arriving while a timer is armed does not arm a second timer;
   *  - `PROGRESS_EMIT_INTERVAL_MS` is short enough (~5 fps) that a status line never looks
   *    frozen, and the update that arrives last is always published by `finishProgress()`
   *    when the pass ends, so nothing is lost at the end of a phase or of the run.
   *
   * Threading: this is called from the engine's awaiting chain, which runs on the UI
   * context's main task queue — the same queue the page renders on — and the timer below
   * fires there too. No shared state crosses a thread, so there is nothing to marshal. The
   * one thing that *is* marshalled is the write of `this.pendingProgress`: doing it here and
   * emitting from the main-queue timer means even a hypothetical off-thread caller would
   * only ever hand over an immutable snapshot.
   */
  private onEngineProgress(progress: SyncProgress, callback: SyncProgressCallback | undefined): void {
    this.pendingProgress = progress;
    if (callback !== undefined) {
      try {
        callback(progress);
      } catch (err) {
        // The caller's UI handler must not be able to abort a sync pass, for the same
        // reason a misbehaving observer cannot.
        hilog.warn(DOMAIN, TAG, 'progress callback threw: %{public}s', String(err));
      }
    }
    const now: number = Date.now();
    if (now - this.lastEmitAt >= PROGRESS_EMIT_INTERVAL_MS) {
      this.publishProgress();
    } else if (this.progressTimer === -1) {
      // Timer typed as `number`: `setTimeout`'s declared return is a `number` here, and
      // `clearTimeout` takes the same value back — see the `flushTimer` in `Index.ets`.
      this.progressTimer = setTimeout((): void => {
        this.progressTimer = -1;
        this.publishProgress();
      }, PROGRESS_EMIT_INTERVAL_MS - (now - this.lastEmitAt));
    }
  }

  /** Publish the newest report to the observers. */
  private publishProgress(): void {
    this.lastEmitAt = Date.now();
    this.message = this.pendingProgress === undefined ? this.message : this.pendingProgress.message;
    this.completed = this.pendingProgress === undefined ? this.completed : this.pendingProgress.completed;
    this.total = this.pendingProgress === undefined ? this.total : this.pendingProgress.total;
    this.emit();
  }

  /** Begin a pass's progress reporting. Clears anything left from the previous one. */
  private beginProgress(): void {
    this.cancelProgressTimer();
    this.pendingProgress = undefined;
    this.lastEmitAt = 0;
  }

  /**
   * End a pass's progress reporting, publishing whatever is pending first.
   *
   * The final publish is not an optimization: without it the last report before the pass
   * finished could still be sitting in `pendingProgress` when the summary line overwrote
   * it, and the user would see the counter stop one file short of the total.
   */
  private finishProgress(): void {
    this.cancelProgressTimer();
    if (this.pendingProgress !== undefined) {
      this.publishProgress();
    }
  }

  /** Disarm the pending coalescing timer, if any. */
  private cancelProgressTimer(): void {
    if (this.progressTimer !== -1) {
      clearTimeout(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /** The stored configuration, for populating the settings form. */
  currentConfig(): WebDavConfig {
    return this.config;
  }

  isConfigured(): boolean {
    return this.configured;
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * Validate a candidate configuration without saving it.
   *
   * `remoteRoot` is sanitized the same way a save would sanitize it, so what is
   * tested is exactly what would be stored.
   */
  async testConnection(
    url: string,
    username: string,
    password: string,
    allowInsecure: boolean,
    remoteRoot: string,
  ): Promise<void> {
    const candidate: WebDavConfig = this.withConnectionDetails(
      url,
      username,
      allowInsecure,
      remoteRoot,
    );
    const client: WebDavClient = new WebDavClient(candidate, password);
    const engine: SyncEngine = this.buildEngine(client, candidate);
    try {
      await engine.testConnection();
    } finally {
      client.dispose();
    }
  }

  /**
   * Persist connection details.
   *
   * The password is written to the credential store and the rest to preferences.
   * An empty password clears the stored credential rather than leaving the old
   * one in place, so "clear the field and save" does what the user expects.
   */
  async saveConnection(
    url: string,
    username: string,
    password: string,
    allowInsecure: boolean,
    remoteRoot: string,
  ): Promise<void> {
    const next: WebDavConfig = this.withConnectionDetails(url, username, allowInsecure, remoteRoot);
    await this.configStore.save(next);
    await this.credentials.setWebDavPassword(password);

    this.config = next;
    this.dropEngines(); // rebuilt lazily against the new settings
    this.configured = next.url.length > 0 && next.username.length > 0
      && await this.credentials.hasWebDavPassword();
    this.lastError = '';
    this.status = SyncRunStatus.IDLE;
    this.emit();
  }

  /** Update the sync toggles without touching the connection. */
  async savePreferences(
    autoSync: boolean,
    syncIntervalMins: number,
    wifiOnly: boolean,
    concurrency: number,
  ): Promise<void> {
    await this.configStore.updatePreferences(autoSync, syncIntervalMins, wifiOnly, concurrency);
    this.config = await this.configStore.load();
    this.dropEngines();
    this.emit();
  }

  /** Forget the configuration and the password. */
  async clearConfiguration(): Promise<void> {
    await this.credentials.clearWebDavPassword();
    await this.configStore.clear();
    this.config = await this.configStore.load();
    this.dropEngines();
    this.configured = false;
    this.status = SyncRunStatus.IDLE;
    this.message = '';
    this.lastError = '';
    this.emit();
  }

  /**
   * Forget both engines, the shared transport, and the decided protocol.
   *
   * One method rather than four assignments at each call site: a client left behind after
   * a configuration change would keep sending the old credentials — and, worse, a stale
   * *protocol* decision would route the next pass to the engine for the server the user
   * just stopped pointing at.
   */
  private dropEngines(): void {
    this.engine = undefined;
    this.v1Engine = undefined;
    this.client = undefined;
    this.protocol = undefined;
    this.refusal = '';
    this.lastSummary = '';
  }

  /**
   * Run one pass.
   *
   * Concurrent calls are refused rather than queued: two passes writing the same
   * remote files would race each other on a server with no locking, which is the
   * one failure mode this protocol cannot recover from by itself.
   *
   * `onProgress` is called with each coalesced report *and* the same values are published
   * through `observe`, so a caller that keeps the callback gets the fine-grained line while
   * anything else on screen still updates. The callback runs on the pass's own task queue —
   * the UI's — so it may touch component state directly.
   */
  async syncNow(mode: SyncMode, onProgress?: SyncProgressCallback): Promise<BookTransferCounts> {
    if (this.running) {
      throw new InkBoatError(SyncErrorKind.CONFIG, '同步已在进行中。');
    }
    if (!this.configured) {
      throw new InkBoatError(SyncErrorKind.CONFIG, '尚未配置 WebDAV，请先在同步设置中填写。');
    }
    if (!await isSyncAllowedNow(this.config.wifiOnly)) {
      throw new InkBoatError(
        SyncErrorKind.CONFIG,
        '当前不在 Wi-Fi 网络，已按设置跳过同步。',
      );
    }

    this.running = true;
    this.status = SyncRunStatus.CHECKING;
    this.message = '准备同步...';
    this.completed = 0;
    this.total = 0;
    this.lastSummary = '';
    this.beginProgress();
    this.emit();

    try {
      // ---- route ------------------------------------------------------------
      // Which engine runs is decided by the shape of the remote index, and nothing is
      // written before that decision is made. A refusal therefore leaves the remote
      // exactly as it was and reaches the user as the message naming what was found —
      // not as a generic failure, and never as "the server looked empty".
      const decision: ProtocolDecision = await this.detectProtocolDecision();
      if (decision.isRefused()) {
        throw protocolRefusalError(decision);
      }
      // A full mode on a v1 server used to be refused here, because the v1 path had no
      // file phase and accepting 全量下载 would have been a lie about what happened. It has
      // one now, so all three modes are served and the refusal is gone. What the modes map
      // onto is `v1OptionsForMode`, and `forceApply` is never part of it — see that
      // function for why v1 cannot use the v2 policy table's FULL_DOWNLOAD row.

      this.status = SyncRunStatus.RUNNING;
      this.message = `${labelForMode(mode)}...`;
      this.emit();

      if (decision.protocol === SyncProtocol.V1) {
        const v1Counts: BookTransferCounts = await this.runV1Pass(mode, onProgress);
        this.lastCounts = v1Counts;
        this.status = v1Counts.failed > 0 ? SyncRunStatus.FAILED : SyncRunStatus.SUCCESS;
        this.message = this.lastSummary;
        this.lastError = '';
        return v1Counts;
      }

      const engine: SyncEngine = await this.ensureEngine();
      const counts: BookTransferCounts = await engine.runSync(
        mode,
        (progress: SyncProgress): void => {
          this.onEngineProgress(progress, onProgress);
        },
      );

      this.lastCounts = counts;
      this.status = counts.failed > 0 ? SyncRunStatus.FAILED : SyncRunStatus.SUCCESS;
      this.message = counts.failed > 0
        ? `同步完成，${counts.failed} 项失败`
        : '同步完成';
      this.lastError = '';
      return counts;
    } catch (err) {
      const message: string = err instanceof InkBoatError || err instanceof Error
        ? (err as Error).message
        : String(err);
      this.status = SyncRunStatus.FAILED;
      this.lastError = message;
      this.message = message;
      // A rejected credential means the stored password is wrong or revoked, so
      // the configuration is no longer usable until the user fixes it.
      if (err instanceof InkBoatError && err.needsCredentials()) {
        this.configured = false;
      }
      throw err instanceof InkBoatError
        ? err
        : new InkBoatError(SyncErrorKind.UNKNOWN, message);
    } finally {
      this.running = false;
      // Before the final emit, so the last progress report is published rather than dropped
      // when the summary below replaces it. Also clears a pending timer, which must not fire
      // after the pass has ended and rewrite the finished status line.
      this.finishProgress();
      this.emit();
    }
  }

  /** True when the stored credential is still usable. */
  async verifyCredentialPresent(): Promise<boolean> {
    try {
      return await this.credentials.hasWebDavPassword();
    } catch (err) {
      return false;
    }
  }

  /** The shared transport, built from the stored password on first use. */
  private async ensureClient(): Promise<WebDavClient> {
    if (this.client !== undefined) {
      return this.client;
    }
    const password: string = await this.credentials.getWebDavPassword();
    if (password.length === 0) {
      throw new InkBoatError(SyncErrorKind.CONFIG, '未找到 WebDAV 密码，请重新填写。');
    }
    const client: WebDavClient = new WebDavClient(this.config, password);
    this.client = client;
    return client;
  }

  private async ensureEngine(): Promise<SyncEngine> {
    if (this.engine !== undefined) {
      return this.engine;
    }
    const client: WebDavClient = await this.ensureClient();
    const engine: SyncEngine = this.buildEngine(client, this.config);
    this.engine = engine;
    return engine;
  }

  /**
   * The v1 engine, built with the v1 file phase.
   *
   * The sixth argument is a `V1FilePhase`, and the engine sees it only as `V1FileRunner` —
   * one method, no delete, no move, no listing. Keeping the concrete phase out of the
   * engine's type is what makes "the v1 metadata engine cannot delete anything remote" a
   * property of the interface rather than a promise about its implementation.
   */
  private async ensureV1Engine(): Promise<SyncV1Engine> {
    if (this.v1Engine !== undefined) {
      return this.v1Engine;
    }
    const client: WebDavClient = await this.ensureClient();
    const books: Books = new Books(this.db);
    const files: V1FilePhase = new V1FilePhase(client, this.config, books, this.storage);
    const engine: SyncV1Engine = new SyncV1Engine(
      client, this.config, this.db, undefined, undefined, files,
    );
    this.v1Engine = engine;
    return engine;
  }

  /**
   * Read the remote index once and decide the protocol from its shape.
   *
   * Uses `SyncV1Engine.loadIndex`, which is the one reader that keeps "absent" apart from
   * "unparseable" (through `readJsonDocument`), and `decideProtocol`, which is the one
   * place the routing table lives. Writes nothing: this is the read the refusal path is
   * built on, so it must be safe to call before any decision.
   */
  private async detectProtocolDecision(): Promise<ProtocolDecision> {
    const engine: SyncV1Engine = await this.ensureV1Engine();
    const index: V1IndexLoad = await engine.loadIndex();
    const decision: ProtocolDecision = decideProtocol(index);
    this.protocol = decision.protocol;
    this.refusal = decision.refusal;
    this.emit();
    return decision;
  }

  /**
   * Decide, and report, which protocol the configured server speaks.
   *
   * Public so the settings screen can answer "which one is my server?" without running a
   * pass. It writes nothing, which is what makes it safe to call on a screen the user has
   * only just opened.
   */
  async detectProtocol(): Promise<SyncProtocol> {
    const decision: ProtocolDecision = await this.detectProtocolDecision();
    return decision.protocol;
  }

  /** The decided protocol as a label for the settings screen. */
  protocolLabel(): string {
    return describeProtocol(this.protocol ?? SyncProtocol.REFUSED);
  }

  /** The message behind the last refusal, or empty when the last decision was usable. */
  protocolMessage(): string {
    return this.refusal;
  }

  /** The last v1 pass's summary line; empty after a v2 pass. */
  lastSummaryOf(): string {
    return this.lastSummary;
  }

  /**
   * True when the last decision was the v1 per-device dialect.
   *
   * The progress reports of the two dialects count different things — v2 counts book
   * files, v1 counts devices — so the card needs to know which noun to use. Read from the
   * decision that is already in force rather than passed alongside every report: a second
   * channel could disagree with the reports themselves.
   */
  isV1Protocol(): boolean {
    return this.protocol === SyncProtocol.V1;
  }

  /**
   * The noun the progress counter should use for the report it is showing.
   *
   * Three cases, and the third is the one that made this a method rather than a ternary at
   * the call site: a v1 pass has **two** phases that count different things. The first
   * counts devices (its snapshots), the second counts files (uploads and downloads), and
   * both speak the same protocol. Reporting "设备 4 / 4" while four book files are moving
   * would name work that is not happening, which is the same defect the v1/v2 split exists
   * to avoid.
   */
  progressUnit(): string {
    if (this.protocol !== SyncProtocol.V1) {
      return '文件';
    }
    return this.v1FilePhaseActive ? '文件' : '设备';
  }

  /**
   * Why an **automatic** pass must not run, or an empty string when it may.
   *
   * Automatic sync runs the v2 per-book protocol only, and that is a deliberate choice
   * rather than a limitation. A v1 pass publishes this device's whole library as a
   * per-device snapshot and merges every other device's snapshot into the local database —
   * it is the pass that can delete rows, and it is pointed at a server whose dialect the
   * user has not necessarily seen. A launch is not the moment to make that decision on the
   * user's behalf.
   *
   * So the gate is explicit and its outcome is shown: `''` means the ordinary v2 pass may
   * proceed, a non-empty string is the line the shell puts on the sync status. The existing
   * `autoSync` setting is unchanged and still consulted first — with the switch off,
   * `autoSyncOnStartup` returns before this is ever reached, so no request is made at all.
   * A refusal stops the launch pass too: a server whose index cannot be read is not a
   * server to write to automatically.
   */
  async autoSyncGate(): Promise<string> {
    const protocol: SyncProtocol = await this.detectProtocol();
    if (protocol === SyncProtocol.V2) {
      return '';
    }
    if (protocol === SyncProtocol.V1) {
      return '启动同步已跳过：远端是 ReadAny v1（每设备快照）格式。'
        + '自动同步不会自动运行 v1 通道，请在同步设置中手动运行一次。';
    }
    return `启动同步已停止：${this.refusal}`;
  }

  /**
   * Run one v1 pass: the per-device metadata protocol, then the file phase.
   *
   * Pulls every other device's snapshot, merges it, publishes this device's own full
   * snapshot, merges this device's entry into the index — and then moves book files and
   * covers. Nothing in either half removes or renames anything on the server: see
   * `ensureV1Engine` and `V1FilePhase.ets` for the three v1.3.6 routines that are absent
   * on purpose.
   *
   * The **mode** decides the file half, through `v1OptionsForMode`. It does not touch the
   * metadata half's timestamps: `forceApply` is false in every mode, because on v1 that
   * flag disables every guard and lets an older remote snapshot overwrite newer local
   * rows.
   *
   * Progress is translated into the shape the existing card already renders, so the
   * settings screen needs no second progress idiom. The counter's unit is not fixed: the
   * metadata half counts devices and the file half counts transfers, and `v1FilePhaseActive`
   * is what lets `progressUnit()` name the right noun. Reporting "设备 4 / 4" while four
   * book files are moving would describe work that is not happening.
   *
   * The returned counts feed the shell's summary. The file counters come from the engine's
   * own `files` report, never from a local tally, so they cannot disagree with what the
   * summary line says.
   */
  private async runV1Pass(
    mode: SyncMode,
    onProgress?: SyncProgressCallback,
  ): Promise<BookTransferCounts> {
    const engine: SyncV1Engine = await this.ensureV1Engine();
    this.v1FilePhaseActive = false;
    const result: V1SyncResult = await engine.runSync(
      v1OptionsForMode(mode),
      (progress: V1Progress): void => {
        // The summary message is a non-empty human line, so "contains both Chinese
        // characters of 文件" is the phase test rather than a heuristic on the counter. The
        // device lines this engine emits are `准备同步...` / `获取其他设备的变更...` /
        // `应用设备 …` / `上传 …条变更`, none of which contains 文件.
        this.v1FilePhaseActive = progress.message.includes('文件');
        this.onEngineProgress(
          progressFromV1(progress.message, progress.completed, progress.total),
          onProgress,
        );
      },
    );
    this.v1FilePhaseActive = false;
    this.lastSummary = describeV1Result(result);
    if (!result.success) {
      // The engine reports a failed pass as a result rather than by throwing, so that the
      // counts it did achieve are not lost. The facade turns it back into an error: the
      // caller's contract is "a throw means the pass failed", and the failure line the
      // shell shows is the message from here.
      throw new InkBoatError(SyncErrorKind.UNKNOWN, result.error);
    }
    const counts: BookTransferCounts = emptyTransferCounts();
    counts.pulled = result.counts.applied;
    counts.skipped = result.counts.skipped;
    counts.pushed = result.counts.tablesUploaded;
    // The file half's real numbers, taken from the engine's report. `failed` drives the
    // pass's status, so a file that would not move surfaces as a failed sync rather than
    // as a silent success.
    counts.uploaded = result.files.filesUploaded;
    counts.downloaded = result.files.filesDownloaded;
    counts.failed = result.files.filesFailed;
    return counts;
  }

  private buildEngine(client: WebDavClient, config: WebDavConfig): SyncEngine {
    const books: Books = new Books(this.db);
    // The runner is what gives the engine file transfers; without it the engine
    // syncs metadata only. It is constructed here, with the same client the engine
    // uses, so a pass cannot transfer binaries through a different credential set
    // than the one the metadata went through.
    const runner: FileStorageRunner = new FileStorageRunner(client, config, books, this.storage);
    return new Engine(
      client,
      config,
      this.db,
      books,
      new Highlights(this.db),
      new Notes(this.db),
      new Bookmarks(this.db),
      // Groups travel through the profile layer, which belongs to the metadata pass.
      new BookGroups(this.db),
      runner,
    );
  }

  /** Apply connection fields onto the current configuration. */
  private withConnectionDetails(
    url: string,
    username: string,
    allowInsecure: boolean,
    remoteRoot: string,
  ): WebDavConfig {
    return {
      url: sanitizeWebDavUrl(url),
      username: username.trim(),
      remoteRoot: sanitizeWebDavRemoteRoot(remoteRoot),
      allowInsecure: allowInsecure,
      autoSync: this.config.autoSync,
      syncIntervalMins: this.config.syncIntervalMins,
      wifiOnly: this.config.wifiOnly,
      concurrency: this.config.concurrency,
    };
  }
}
