import AsyncStorage from '@react-native-async-storage/async-storage';
import { useSyncExternalStore } from 'react';
import { AppConfig } from '../config';
import type { DirectoryStatus, ExitNodeRegion, LatencyState } from '../model/exitNode';
import { regionKey } from '../model/exitNode';
import { firstReachable } from '../net/brokerClient';
import { loadExitNodeDirectory } from '../net/exitNodeDirectory';
import { runLatencyProbe } from '../net/latencyProbe';
import type { NativeVpnState, TrafficStats } from '../native/types';

/**
 * Minimal external store holding the contract §4 AppState (mirrors the production
 * `OpenRungUiState`): the native slice is mirrored from `OpenRungVpn` events; the directory slice
 * reproduces `OpenRungStatusStore.refreshDirectory`.
 */

export interface AppState {
  native: NativeVpnState; // mirrored from native
  brokerUrl: string; // fixed to config default (not editable)
  directoryStatus: DirectoryStatus;
  availableRegions: ExitNodeRegion[];
  languageTag: string; // '' = system, persisted in AsyncStorage
  favorites: string[]; // favorited exit countries (ISO alpha-2, uppercase, insertion order)
  autoConnectEnabled: boolean;
  rememberExitEnabled: boolean;
  lastExitCountry: string | null; // last requested exit ('' persisted = broker picks)
  prefsHydrated: boolean; // guards auto-connect until AsyncStorage has been read
  traffic: TrafficStats | null; // live ~2s samples while connected, null otherwise
  latency: LatencyState; // on-demand exit-location latency probe results
}

export const LANGUAGE_STORAGE_KEY = 'openrung.language';
export const FAVORITES_STORAGE_KEY = 'openrung.favorites';
export const AUTO_CONNECT_STORAGE_KEY = 'openrung.autoConnect';
export const REMEMBER_EXIT_STORAGE_KEY = 'openrung.rememberExit';
export const LAST_EXIT_STORAGE_KEY = 'openrung.lastExit';

const INITIAL_NATIVE_STATE: NativeVpnState = {
  status: 'disconnected',
  relayLabel: null,
  lastError: null,
  logLines: [],
  recents: [],
};

function initialState(): AppState {
  return {
    native: INITIAL_NATIVE_STATE,
    brokerUrl: AppConfig.DEFAULT_BROKER_URL,
    directoryStatus: 'idle',
    availableRegions: [],
    languageTag: '',
    favorites: [],
    autoConnectEnabled: false,
    rememberExitEnabled: true,
    lastExitCountry: null,
    prefsHydrated: false,
    traffic: null,
    latency: { status: 'idle', results: {}, testedAtMs: null },
  };
}

let state: AppState = initialState();
const listeners = new Set<() => void>();

// Supersession token for directory loads: mirrors production's `directoryJob?.cancel()` — a
// newer (forced) refresh makes any in-flight load stale so its completion can't clobber state.
let directoryGeneration = 0;
// Same idiom for the latency probe: a newer run (or a directory refresh) supersedes an in-flight one.
let latencyGeneration = 0;

function setState(next: AppState): void {
  state = next;
  for (const listener of listeners) {
    listener();
  }
}

export function getSnapshot(): AppState {
  return state;
}

export function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** React hook over the external store. */
export function useAppState(): AppState {
  return useSyncExternalStore(subscribe, getSnapshot);
}

/** Mirrors a `NativeVpnState` (from getState() or an openrungStateChanged event) into the store. */
export function applyNativeState(native: NativeVpnState): void {
  // Belt-and-braces alongside the native zeroed traffic emission: any status other than
  // connected clears the live traffic sample.
  const traffic = native.status === 'connected' ? state.traffic : null;
  setState({ ...state, native, traffic });
}

/** Mirrors an `openrungTrafficChanged` sample (or getTrafficStats() seed) into the store. */
export function applyTrafficStats(traffic: TrafficStats | null): void {
  setState({ ...state, traffic });
}

/**
 * Refreshes the exit-node map directory from the broker. No-op while a load is in flight or
 * after a successful non-empty load, unless `force` is set (used by manual retry) — exactly the
 * production `OpenRungStatusStore.refreshDirectory` semantics.
 *
 * Returns a promise that settles when the load completes (never rejects); production is
 * fire-and-forget, the promise exists purely for deterministic tests.
 */
export function refreshDirectory(force: boolean = false): Promise<void> {
  const current = state;
  const alreadyLoaded =
    current.directoryStatus === 'loaded' && current.availableRegions.length > 0;
  if (!force && (current.directoryStatus === 'loading' || alreadyLoaded)) {
    return Promise.resolve();
  }

  const generation = ++directoryGeneration;
  setState({ ...state, directoryStatus: 'loading' });

  const brokerEndpoints = AppConfig.brokerCandidates(state.brokerUrl);
  return loadExitNodeDirectory({
    fetchRelays: async () =>
      (await firstReachable(brokerEndpoints, { limit: AppConfig.DIRECTORY_RELAY_LIMIT })).response,
  })
    .then(regions => {
      if (generation !== directoryGeneration) {
        return; // superseded by a newer refresh — don't clobber its result
      }
      // A new relay set invalidates any prior latency probes (endpoints may have changed).
      latencyGeneration++;
      setState({
        ...state,
        availableRegions: regions,
        directoryStatus: 'loaded',
        latency: { status: 'idle', results: {}, testedAtMs: null },
      });
    })
    .catch(() => {
      if (generation !== directoryGeneration) {
        return;
      }
      setState({ ...state, directoryStatus: 'failed' });
    });
}

/**
 * Runs the on-demand exit-location latency probe over the current directory. Uses the same
 * supersession-token idiom as `refreshDirectory` so a newer run (or a directory refresh) wins.
 * Never rejects; failures land as `status: 'failed'`.
 */
export function runLatencyTest(): Promise<void> {
  const regions = state.availableRegions;
  if (regions.length === 0) {
    return Promise.resolve();
  }
  const generation = ++latencyGeneration;
  setState({ ...state, latency: { ...state.latency, status: 'running' } });

  return runLatencyProbe(regions)
    .then(results => {
      if (generation !== latencyGeneration) {
        return; // superseded — don't clobber a newer run / refresh
      }
      setState({
        ...state,
        latency: { status: 'done', results, testedAtMs: Date.now() },
      });
    })
    .catch(() => {
      if (generation !== latencyGeneration) {
        return;
      }
      setState({ ...state, latency: { ...state.latency, status: 'failed' } });
    });
}

/**
 * Lowest-latency country among fresh probe results (pure — safe to call after awaiting
 * `runLatencyTest`). A country's best city wins; unreachable regions are ignored. Returns null
 * when there are no reachable results.
 */
export function fastestCountry(
  snapshot: AppState,
): { countryCode: string; rttMs: number } | null {
  const byRegion = snapshot.latency.results;
  let best: { countryCode: string; rttMs: number } | null = null;
  for (const region of snapshot.availableRegions) {
    const result = byRegion[regionKey(region)];
    if (result == null || result.rttMs === null) {
      continue;
    }
    if (best === null || result.rttMs < best.rttMs) {
      best = { countryCode: region.countryCode, rttMs: result.rttMs };
    }
  }
  return best;
}

/** Sets the in-app language tag ('' = system default) and persists it to AsyncStorage. */
export function setLanguageTag(tag: string): void {
  setState({ ...state, languageTag: tag });
  AsyncStorage.setItem(LANGUAGE_STORAGE_KEY, tag).catch(() => {
    // Persistence is best-effort, like production's autoStoreLocales.
  });
}

/** Loads the persisted language selection (called once by the LanguageProvider on mount). */
export async function hydrateLanguage(): Promise<void> {
  try {
    const persisted = await AsyncStorage.getItem(LANGUAGE_STORAGE_KEY);
    if (persisted !== null && persisted !== state.languageTag) {
      setState({ ...state, languageTag: persisted });
    }
  } catch {
    // Best-effort: fall back to the in-memory default ('' = system).
  }
}

/** Adds/removes a country from the favorite exit locations and persists the list. */
export function toggleFavorite(countryCode: string): void {
  const code = countryCode.trim().toUpperCase();
  if (code.length === 0) {
    return;
  }
  const favorites = state.favorites.includes(code)
    ? state.favorites.filter(existing => existing !== code)
    : [...state.favorites, code];
  setState({ ...state, favorites });
  AsyncStorage.setItem(FAVORITES_STORAGE_KEY, JSON.stringify(favorites)).catch(() => {
    // Best-effort persistence, like setLanguageTag.
  });
}

export function setAutoConnectEnabled(enabled: boolean): void {
  setState({ ...state, autoConnectEnabled: enabled });
  AsyncStorage.setItem(AUTO_CONNECT_STORAGE_KEY, enabled ? 'true' : 'false').catch(() => {});
}

export function setRememberExitEnabled(enabled: boolean): void {
  setState({ ...state, rememberExitEnabled: enabled });
  AsyncStorage.setItem(REMEMBER_EXIT_STORAGE_KEY, enabled ? 'true' : 'false').catch(() => {});
}

/**
 * Records the exit the user last REQUESTED (null = broker picks), so auto-connect can return to
 * it. No-op while "remember last exit" is off. Persists '' for the broker-picks case.
 */
export function recordLastExit(country: string | null): void {
  if (!state.rememberExitEnabled) {
    return;
  }
  const code = country?.trim().toUpperCase() ?? null;
  setState({ ...state, lastExitCountry: code });
  AsyncStorage.setItem(LAST_EXIT_STORAGE_KEY, code ?? '').catch(() => {});
}

/**
 * Loads favorites + connection preferences in one round trip. Always ends with
 * `prefsHydrated: true` (even on storage failure) so auto-connect can make its
 * one-shot decision. Called once from the app root on mount.
 */
export async function hydratePreferences(): Promise<void> {
  let favorites = state.favorites;
  let autoConnectEnabled = state.autoConnectEnabled;
  let rememberExitEnabled = state.rememberExitEnabled;
  let lastExitCountry = state.lastExitCountry;
  try {
    // AsyncStorage v3 has no multiGet; four parallel getItem calls instead.
    const [rawFavorites, rawAutoConnect, rawRememberExit, rawLastExit] = await Promise.all([
      AsyncStorage.getItem(FAVORITES_STORAGE_KEY),
      AsyncStorage.getItem(AUTO_CONNECT_STORAGE_KEY),
      AsyncStorage.getItem(REMEMBER_EXIT_STORAGE_KEY),
      AsyncStorage.getItem(LAST_EXIT_STORAGE_KEY),
    ]);
    if (rawFavorites != null) {
      try {
        const parsed: unknown = JSON.parse(rawFavorites);
        if (Array.isArray(parsed) && parsed.every(item => typeof item === 'string')) {
          favorites = parsed;
        }
      } catch {
        // Malformed favorites payload: keep the in-memory default.
      }
    }
    if (rawAutoConnect != null) {
      autoConnectEnabled = rawAutoConnect === 'true';
    }
    if (rawRememberExit != null) {
      rememberExitEnabled = rawRememberExit === 'true';
    }
    if (rawLastExit != null) {
      lastExitCountry = rawLastExit === '' ? null : rawLastExit;
    }
  } catch {
    // Best-effort: defaults stand, but hydration still completes below.
  }
  setState({
    ...state,
    favorites,
    autoConnectEnabled,
    rememberExitEnabled,
    lastExitCountry,
    prefsHydrated: true,
  });
}

/** Test-only: resets the store to its initial state. */
export function resetStoreForTests(): void {
  directoryGeneration++;
  latencyGeneration++;
  state = initialState();
}
