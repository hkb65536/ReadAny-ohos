/**
 * Network state, for the "sync on Wi-Fi only" preference.
 *
 * Sync is not on a fixed schedule: it is triggered on start-up, on foreground and
 * on demand. Before each pass the engine asks whether the current network
 * satisfies the user's preference, and this is where that answer comes from.
 *
 * `bearerTypes` is checked rather than `networkCap` because capability bits vary
 * by carrier and by API level, while the bearer type is the stable signal for
 * "is this Wi-Fi".
 */

import { connection } from '@kit.NetworkKit';

/** What the engine needs to know about connectivity. */
export interface NetworkState {
  /** True when any default network exists. */
  connected: boolean;
  /** True when the default network is Wi-Fi. */
  wifi: boolean;
  /**
   * True when the default network is metered from the user's point of view
   * (cellular). Ethernet and VPN over Wi-Fi are treated as unmetered.
   */
  metered: boolean;
}

function unknownState(): NetworkState {
  return { connected: false, wifi: false, metered: false };
}

/**
 * Read the current network state.
 *
 * Never throws: a failure to determine connectivity is reported as "not
 * connected" rather than as an error, because the caller's decision is the same
 * either way (do not run a Wi-Fi-only sync) and a sync pass should not fail
 * because a status query did.
 */
export async function readNetworkState(): Promise<NetworkState> {
  let handle: connection.NetHandle;
  try {
    handle = await connection.getDefaultNet();
  } catch (err) {
    return unknownState();
  }

  // `netId === 0` means there is no default network. `getDefaultNet` resolves
  // with this sentinel rather than rejecting, so it has to be checked explicitly.
  if (handle === undefined || handle === null || handle.netId === 0) {
    return unknownState();
  }

  let capabilities: connection.NetCapabilities;
  try {
    capabilities = await connection.getNetCapabilities(handle);
  } catch (err) {
    // Reachable network, unknown characteristics: assume connected and metered,
    // which is the conservative combination for a Wi-Fi-only preference.
    return { connected: true, wifi: false, metered: true };
  }

  const bearers: connection.NetBearType[] = capabilities.bearerTypes ?? [];
  const wifi: boolean = bearers.includes(connection.NetBearType.BEARER_WIFI)
    || bearers.includes(connection.NetBearType.BEARER_ETHERNET);
  const cellular: boolean = bearers.includes(connection.NetBearType.BEARER_CELLULAR);

  return {
    connected: true,
    wifi: wifi,
    metered: cellular && !wifi,
  };
}

/** True when a pass may run under the given Wi-Fi-only preference. */
export async function isSyncAllowedNow(wifiOnly: boolean): Promise<boolean> {
  if (!wifiOnly) {
    return true;
  }
  const state: NetworkState = await readNetworkState();
  // Ethernet counts as acceptable: the preference is about avoiding mobile data,
  // not about the specific radio.
  return state.connected && state.wifi;
}
