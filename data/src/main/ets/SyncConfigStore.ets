/**
 * Non-secret sync configuration, persisted in preferences.
 *
 * The split from `CredentialStore` is deliberate: preferences are readable by
 * anything that can read the app sandbox, so only non-secret fields live here.
 * Reusing `WebDavConfig` from the sync layer rather than defining a parallel
 * shape keeps the persisted form and the in-memory form from drifting apart.
 *
 * Fields are stored as individual keys instead of one JSON blob so that adding a
 * field later cannot invalidate an existing configuration, and so a single
 * corrupt value degrades one setting rather than the whole store.
 */

import { preferences } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';
import { InkBoatError, SyncErrorKind } from 'core';
import type { WebDavConfig } from 'sync';
import {
  clampConcurrency,
  DEFAULT_CONCURRENCY,
  DEFAULT_SYNC_INTERVAL_MINS,
  defaultWebDavConfig,
} from 'sync';

const STORE_NAME: string = 'inkboat_sync_config';

const KEY_URL: string = 'webdav_url';
const KEY_USERNAME: string = 'webdav_username';
const KEY_REMOTE_ROOT: string = 'webdav_remote_root';
const KEY_ALLOW_INSECURE: string = 'webdav_allow_insecure';
const KEY_AUTO_SYNC: string = 'auto_sync';
const KEY_SYNC_INTERVAL: string = 'sync_interval_mins';
const KEY_WIFI_ONLY: string = 'wifi_only';
const KEY_CONCURRENCY: string = 'concurrency';

/** The persisted configuration plus what the UI needs to know about it. */
export interface StoredSyncConfig {
  config: WebDavConfig;
  /**
   * True when URL and username are present *and* a password exists in the
   * credential store. Computed by the caller, which is the only party that can
   * see both halves.
   */
  hasConnectionDetails: boolean;
}

function fail(action: string, err: Object): InkBoatError {
  const message: string = err instanceof Error ? err.message : JSON.stringify(err);
  return new InkBoatError(SyncErrorKind.CONFIG, `${action}：${message}`);
}

export class SyncConfigStore {
  private readonly prefs: preferences.Preferences;

  private constructor(prefs: preferences.Preferences) {
    this.prefs = prefs;
  }

  /** Open (or create) the preferences store. */
  static async open(context: common.UIAbilityContext): Promise<SyncConfigStore> {
    try {
      const prefs: preferences.Preferences =
        await preferences.getPreferences(context, STORE_NAME);
      return new SyncConfigStore(prefs);
    } catch (err) {
      throw fail('打开同步配置失败', err as Object);
    }
  }

  /** Read the stored configuration, falling back to defaults per field. */
  async load(): Promise<WebDavConfig> {
    const base: WebDavConfig = defaultWebDavConfig();
    const url: string = await this.readString(KEY_URL, base.url);
    const username: string = await this.readString(KEY_USERNAME, base.username);
    const remoteRoot: string = await this.readString(KEY_REMOTE_ROOT, base.remoteRoot);

    return {
      url: url,
      username: username,
      remoteRoot: remoteRoot,
      allowInsecure: await this.readBoolean(KEY_ALLOW_INSECURE, base.allowInsecure),
      autoSync: await this.readBoolean(KEY_AUTO_SYNC, base.autoSync),
      syncIntervalMins: await this.readNumber(KEY_SYNC_INTERVAL, DEFAULT_SYNC_INTERVAL_MINS),
      wifiOnly: await this.readBoolean(KEY_WIFI_ONLY, base.wifiOnly),
      concurrency: clampConcurrency(await this.readNumber(KEY_CONCURRENCY, DEFAULT_CONCURRENCY)),
    };
  }

  /**
   * Write the configuration.
   *
   * Every field is written on every save, so a value the caller left at its
   * default is persisted as the default rather than silently kept from a
   * previous configuration the user has since changed.
   */
  async save(config: WebDavConfig): Promise<void> {
    try {
      await this.prefs.put(KEY_URL, config.url);
      await this.prefs.put(KEY_USERNAME, config.username);
      await this.prefs.put(KEY_REMOTE_ROOT, config.remoteRoot);
      await this.prefs.put(KEY_ALLOW_INSECURE, config.allowInsecure);
      await this.prefs.put(KEY_AUTO_SYNC, config.autoSync);
      await this.prefs.put(KEY_SYNC_INTERVAL, config.syncIntervalMins);
      await this.prefs.put(KEY_WIFI_ONLY, config.wifiOnly);
      await this.prefs.put(KEY_CONCURRENCY, clampConcurrency(config.concurrency));
      // `put` only mutates the in-memory cache; without `flush` the values are
      // lost if the process dies before the store decides to write itself.
      await this.prefs.flush();
    } catch (err) {
      throw fail('保存同步配置失败', err as Object);
    }
  }

  /**
   * Update only the sync preferences, leaving connection details untouched.
   *
   * Used by the settings toggles: flipping "Wi-Fi only" must not require the
   * caller to have the URL and username in hand.
   */
  async updatePreferences(
    autoSync: boolean,
    syncIntervalMins: number,
    wifiOnly: boolean,
    concurrency: number,
  ): Promise<void> {
    const current: WebDavConfig = await this.load();
    current.autoSync = autoSync;
    current.syncIntervalMins = syncIntervalMins;
    current.wifiOnly = wifiOnly;
    current.concurrency = clampConcurrency(concurrency);
    await this.save(current);
  }

  /** Forget everything, for the "remove configuration" action. */
  async clear(): Promise<void> {
    try {
      await this.prefs.clear();
      await this.prefs.flush();
    } catch (err) {
      throw fail('清除同步配置失败', err as Object);
    }
  }

  // -------------------------------------------------------------------------
  // Typed reads
  //
  // `preferences.get` returns `ValueType`, a wide union, so each accessor
  // narrows and falls back rather than casting. A corrupted or type-changed value
  // then degrades to the default instead of throwing during start-up.
  // -------------------------------------------------------------------------

  private async readString(key: string, fallback: string): Promise<string> {
    try {
      const value: preferences.ValueType = await this.prefs.get(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (err) {
      return fallback;
    }
  }

  private async readBoolean(key: string, fallback: boolean): Promise<boolean> {
    try {
      const value: preferences.ValueType = await this.prefs.get(key, fallback);
      return typeof value === 'boolean' ? value : fallback;
    } catch (err) {
      return fallback;
    }
  }

  private async readNumber(key: string, fallback: number): Promise<number> {
    try {
      const value: preferences.ValueType = await this.prefs.get(key, fallback);
      if (typeof value === 'number') {
        return value;
      }
      if (typeof value === 'string') {
        const parsed: number = Number(value);
        return Number.isNaN(parsed) ? fallback : parsed;
      }
      return fallback;
    } catch (err) {
      return fallback;
    }
  }
}
