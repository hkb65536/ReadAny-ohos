/**
 * WebDAV credential storage on the Asset Store Kit.
 *
 * The password goes to `@ohos.security.asset`, which is the platform's store for
 * exactly this kind of short secret: it is encrypted at rest, bound to this
 * device, and never lands in a plain preferences file or the database.
 *
 * Everything else about the connection (URL, username, remote root, sync
 * preferences) is *not* secret and lives in preferences — see
 * `SyncConfigStore`. The split matters because a preferences file is readable by
 * anything that can read the app sandbox, so the password must not be in it.
 *
 * Accessibility is `DEVICE_FIRST_UNLOCKED` rather than `DEVICE_UNLOCKED`: sync is
 * allowed to run after the first unlock following a reboot, including while the
 * screen is locked. `DEVICE_UNLOCKED` would fail those background passes with
 * `ACCESS_DENIED`, and `DEVICE_POWERED_ON` would be weaker than necessary.
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { InkBoatError, SyncErrorKind } from 'core';

/** Error code returned when no matching asset exists. */
const ASSET_NOT_FOUND: number = 24000002;
/** Error code returned when an entry with the same alias already exists. */
const ASSET_DUPLICATED: number = 24000003;
/** Error code returned when the store refuses access (for example still locked). */
const ASSET_ACCESS_DENIED: number = 24000004;
/**
 * Error code returned when the screen-lock state does not match what the asset
 * requires (`24000005 STATUS_MISMATCH`).
 *
 * Distinct from `ACCESS_DENIED` and easy to miss: an asset saved while the device was
 * unlocked and then read while the screen is locked reports *this* code, not
 * `ACCESS_DENIED`. Treating only the latter as "locked" means the common case — a
 * background sync after the screen goes off — surfaces as a generic read failure and
 * the user is told to re-enter a password that was never wrong.
 */
const ASSET_STATUS_MISMATCH: number = 24000005;

/**
 * Alias namespacing.
 *
 * The alias is the primary key of an asset, so every InkBoat secret is prefixed
 * to keep it from colliding with anything else in the app's asset namespace.
 */
const ALIAS_PREFIX: string = 'inkboat.';

/** Read the numeric error code from a thrown BusinessError, or 0. */
function errorCodeOf(err: Object): number {
  if (err === null || err === undefined) {
    return 0;
  }
  const candidate: Object = (err as Record<string, Object>)['code'];
  if (typeof candidate === 'number') {
    return candidate;
  }
  if (typeof candidate === 'string') {
    const parsed: number = Number(candidate);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

function messageOf(err: Object): string {
  if (err instanceof Error) {
    return err.message;
  }
  return JSON.stringify(err);
}

/**
 * Store a secret.
 *
 * An existing entry under the same alias is overwritten rather than treated as an
 * error: the user editing their WebDAV password is the normal case, and
 * `ConflictResolution.THROW_ERROR` (the default) would make the second save fail.
 */
async function putSecret(alias: string, secret: string): Promise<void> {
  const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  attributes.set(asset.Tag.ALIAS, stringToBytes(ALIAS_PREFIX + alias));
  attributes.set(asset.Tag.SECRET, stringToBytes(secret));
  attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  // Keep the secret on this device only. Cross-device sync of a WebDAV password
  // would hand the credential to whatever account sync is configured with, which
  // is not something the user asked for.
  attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
  // `IS_PERSISTENT` is deliberately **not** set.
  //
  // An earlier version set it to `true`, with a comment claiming it was what made the
  // secret survive app restarts. That was wrong: the SDK defines `IS_PERSISTENT` as
  // "whether to retain the asset when the application is uninstalled" (line 891 of
  // `@ohos.security.asset.d.ts`), and assets already survive restarts without it.
  //
  // The mistake was not cosmetic. Setting the tag requires
  // `ohos.permission.STORE_PERSISTENT_DATA`, which this app does not declare, so every
  // save failed at runtime with `201 The caller doesn't have the permission` — the
  // credential could never be stored at all. Adding the permission would have bought
  // only "keep the WebDAV password after the user uninstalls the app", which nobody
  // asked for and which is the wrong answer for a stored password.
  //
  // The intended lifetime is the default one: kept across restarts, removed with the
  // app.
  attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);

  try {
    await asset.add(attributes);
  } catch (err) {
    const code: number = errorCodeOf(err);
    if (code === ASSET_DUPLICATED) {
      // Older store versions reject the overwrite flag; fall back to an update.
      await updateSecret(alias, secret);
      return;
    }
    throw new InkBoatError(
      SyncErrorKind.CONFIG,
      `保存凭据失败：${messageOf(err)}（code ${code}）`,
    );
  }
}

async function updateSecret(alias: string, secret: string): Promise<void> {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, stringToBytes(ALIAS_PREFIX + alias));

  const update: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  update.set(asset.Tag.SECRET, stringToBytes(secret));

  try {
    await asset.update(query, update);
  } catch (err) {
    throw new InkBoatError(
      SyncErrorKind.CONFIG,
      `更新凭据失败：${messageOf(err)}（code ${errorCodeOf(err)}）`,
    );
  }
}

/** Read a secret back, or an empty string when nothing is stored. */
async function getSecret(alias: string): Promise<string> {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, stringToBytes(ALIAS_PREFIX + alias));
  // Without this the store returns only attributes, not the secret itself.
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

  let results: asset.AssetMap[];
  try {
    results = await asset.query(query);
  } catch (err) {
    const code: number = errorCodeOf(err);
    if (code === ASSET_NOT_FOUND) {
      return '';
    }
    // A locked device reports ACCESS_DENIED or STATUS_MISMATCH depending on which
    // part of the accessibility policy it fails. Neither is a configuration error —
    // the credential exists and will be readable once unlocked — so both are
    // surfaced as their own kind rather than as "not configured", which would make
    // the UI claim the user never set a password.
    if (code === ASSET_ACCESS_DENIED || code === ASSET_STATUS_MISMATCH) {
      throw new InkBoatError(
        SyncErrorKind.FORBIDDEN,
        '设备当前已锁定，无法读取 WebDAV 凭据。解锁后重试。',
      );
    }
    throw new InkBoatError(
      SyncErrorKind.CONFIG,
      `读取凭据失败：${messageOf(err)}（code ${code}）`,
    );
  }

  if (results.length === 0) {
    return '';
  }
  const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
  if (secret === undefined) {
    return '';
  }
  return bytesToString(secret);
}

/** Remove a secret. Absent is success. */
async function deleteSecret(alias: string): Promise<void> {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, stringToBytes(ALIAS_PREFIX + alias));
  try {
    await asset.remove(query);
  } catch (err) {
    const code: number = errorCodeOf(err);
    if (code === ASSET_NOT_FOUND) {
      return;
    }
    throw new InkBoatError(
      SyncErrorKind.CONFIG,
      `删除凭据失败：${messageOf(err)}（code ${code}）`,
    );
  }
}

/** True when a secret is stored, without reading it into memory. */
async function hasSecret(alias: string): Promise<boolean> {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, stringToBytes(ALIAS_PREFIX + alias));
  // Attributes only: this probe must not pull the secret out of the keystore.
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
  try {
    const results: asset.AssetMap[] = await asset.query(query);
    return results.length > 0;
  } catch (err) {
    const code: number = errorCodeOf(err);
    if (code === ASSET_NOT_FOUND) {
      return false;
    }
    if (code === ASSET_ACCESS_DENIED || code === ASSET_STATUS_MISMATCH) {
      // The entry exists but cannot be read yet; reporting "present" is the
      // truthful answer and keeps the settings screen from telling the user to
      // re-enter a password they already saved.
      return true;
    }
    throw new InkBoatError(
      SyncErrorKind.CONFIG,
      `检查凭据失败：${messageOf(err)}（code ${code}）`,
    );
  }
}

function stringToBytes(value: string): Uint8Array {
  return new util.TextEncoder().encodeInto(value);
}

function bytesToString(value: asset.Value): string {
  if (typeof value === 'string') {
    return value;
  }
  if (value instanceof Uint8Array) {
    return util.TextDecoder.create('utf-8', { fatal: false }).decodeToString(value);
  }
  return String(value);
}

/** Credential slot names. */
export const CREDENTIAL_WEBDAV_PASSWORD: string = 'sync_webdav_password';

/**
 * Credential access for sync.
 *
 * A thin wrapper rather than free functions so the alias set stays in one place
 * and a future second backend (S3) cannot accidentally reuse the WebDAV slot.
 */
export class CredentialStore {
  /** Persist the WebDAV password. */
  async setWebDavPassword(password: string): Promise<void> {
    if (password.length === 0) {
      await this.clearWebDavPassword();
      return;
    }
    await putSecret(CREDENTIAL_WEBDAV_PASSWORD, password);
  }

  /** Read the WebDAV password, or an empty string when unset. */
  async getWebDavPassword(): Promise<string> {
    return await getSecret(CREDENTIAL_WEBDAV_PASSWORD);
  }

  /** True when a password is stored. */
  async hasWebDavPassword(): Promise<boolean> {
    return await hasSecret(CREDENTIAL_WEBDAV_PASSWORD);
  }

  /** Forget the WebDAV password. */
  async clearWebDavPassword(): Promise<void> {
    await deleteSecret(CREDENTIAL_WEBDAV_PASSWORD);
  }
}
