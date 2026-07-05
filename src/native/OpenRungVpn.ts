import { NativeEventEmitter, NativeModules } from 'react-native';
import { MockOpenRungVpn } from './mock';
import type { NativeVpnState, OpenRungVpnModule, TrafficStats } from './types';

/**
 * Typed wrapper over the `OpenRungVpn` native module (contract §3). When the native module is
 * missing (Jest, fresh Metro without a native rebuild) it automatically falls back to the
 * scripted `MockOpenRungVpn`; `isMock` is exported for the Debug screen to display.
 */

const nativeModule = (NativeModules as Record<string, unknown>).OpenRungVpn as
  | OpenRungVpnModule
  | null
  | undefined;

/** True when the scripted mock is in use instead of a real native module. */
export const isMock = nativeModule == null;

const mock: MockOpenRungVpn | null = isMock ? new MockOpenRungVpn() : null;

/** The active VPN module: the native bridge when built in, otherwise the mock simulator. */
export const OpenRungVpn: OpenRungVpnModule = nativeModule ?? (mock as MockOpenRungVpn);

/**
 * Subscribes to `openrungStateChanged` (payload: `NativeVpnState`, emitted on every
 * status/log/relay/recents change). Returns an unsubscribe function.
 */
export function subscribeVpnState(callback: (state: NativeVpnState) => void): () => void {
  if (mock) {
    return mock.subscribe(callback);
  }
  const emitter = new NativeEventEmitter(NativeModules.OpenRungVpn);
  const subscription = emitter.addListener('openrungStateChanged', callback);
  return () => subscription.remove();
}

/**
 * Subscribes to `openrungTrafficChanged` (payload: `TrafficStats`, ~2 s cadence while
 * connected, one zeroed emission on disconnect). Kept separate from
 * `openrungStateChanged` so the frequent traffic samples don't re-ship the 80-line
 * log + recents across the bridge. Returns an unsubscribe function.
 */
export function subscribeTrafficStats(callback: (stats: TrafficStats) => void): () => void {
  if (mock) {
    return mock.subscribeTraffic(callback);
  }
  const emitter = new NativeEventEmitter(NativeModules.OpenRungVpn);
  const subscription = emitter.addListener('openrungTrafficChanged', callback);
  return () => subscription.remove();
}
