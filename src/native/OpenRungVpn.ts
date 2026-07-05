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

/**
 * Promise-returning methods added after the initial bridge shipped. A native binary OLDER than
 * the JS bundle (e.g. Metro reloaded new JS but the app was never rebuilt) won't implement these;
 * calling a missing one throws "undefined is not a function" SYNCHRONOUSLY — before any `.catch()`
 * runs — which white-screens the app on mount. Wrapping the native module fills any absent method
 * with a rejecting stub, so version skew surfaces as a caught rejection instead of a crash.
 */
const OPTIONAL_METHODS: ReadonlyArray<keyof OpenRungVpnModule> = [
  'getTrafficStats',
  'measureLatency',
  'getInstalledApps',
  'getSplitTunnelConfig',
  'setSplitTunnelConfig',
  'getPersistedLog',
  'clearPersistedLog',
];

function guardOptionalMethods(mod: OpenRungVpnModule): OpenRungVpnModule {
  const optional = new Set<string>(OPTIONAL_METHODS as readonly string[]);
  return new Proxy(mod, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver);
      if (value === undefined && typeof prop === 'string' && optional.has(prop)) {
        return () =>
          Promise.reject(
            new Error(
              `OpenRungVpn.${prop} is unavailable — the native app is out of date. ` +
                'Rebuild it (a JS reload is not enough when native code changed).',
            ),
          );
      }
      return value;
    },
  });
}

/** The active VPN module: the native bridge (guarded for version skew) or the mock simulator. */
export const OpenRungVpn: OpenRungVpnModule = nativeModule
  ? guardOptionalMethods(nativeModule)
  : (mock as MockOpenRungVpn);

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
  try {
    const emitter = new NativeEventEmitter(NativeModules.OpenRungVpn);
    const subscription = emitter.addListener('openrungTrafficChanged', callback);
    return () => subscription.remove();
  } catch {
    // Older native binary that doesn't declare `openrungTrafficChanged` as a supported event:
    // no live traffic stats, but the app must not crash. No-op subscription.
    return () => {};
  }
}
