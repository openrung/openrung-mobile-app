import AsyncStorage from '@react-native-async-storage/async-storage';
import { useSyncExternalStore } from 'react';
import { AppConfig } from '../config';
import type { DirectoryStatus, ExitNodeRegion, HomeViewMode } from '../model/exitNode';
import { INITIAL_UPDATE_UI, type UpdateUiState } from '../model/updateStatus';
import { firstReachable } from '../net/brokerClient';
import { loadExitNodeDirectory } from '../net/exitNodeDirectory';
import { OpenRungVpn } from '../native/OpenRungVpn';
import type { NativeVpnState } from '../native/types';

/**
 * Minimal external store holding the contract §4 AppState (mirrors the production
 * `OpenRungUiState`): the native slice is mirrored from `OpenRungVpn` events; the directory slice
 * reproduces `OpenRungStatusStore.refreshDirectory`.
 */

export interface SplitTunnelState {
  enabled: boolean;
  bypassLan: boolean;
  bypassCountries: string[]; // lowercase ISO codes; v1 recognizes only 'ir' and 'cn'
  excludedApps: string[]; // Android package names (iOS parses and ignores)
}

export interface AppState {
  native: NativeVpnState; // mirrored from native
  brokerUrl: string; // fixed to config default (not editable)
  directoryStatus: DirectoryStatus;
  availableRegions: ExitNodeRegion[];
  languageTag: string; // '' = system, persisted in AsyncStorage
  homeViewMode: HomeViewMode; // home directory presentation, persisted in AsyncStorage
  splitTunnel: SplitTunnelState; // persisted in AsyncStorage, mirrored to the native store
  /**
   * Epoch ms of the moment the native status last ENTERED 'connected' (stamped
   * shell-side, so after an app restart it counts from the first mirrored
   * event). Null whenever the tunnel is not connected. Drives the session
   * uptime readout.
   */
  connectedAtMs: number | null;
  /** In-app update check UI tier, derived and written by state/updateCheck.ts. */
  update: UpdateUiState;
}

export const LANGUAGE_STORAGE_KEY = 'openrung.language';
export const HOME_VIEW_MODE_STORAGE_KEY = 'openrung.homeViewMode';
export const SPLIT_TUNNEL_STORAGE_KEY = 'openrung.splitTunnel';

const INITIAL_NATIVE_STATE: NativeVpnState = {
  status: 'disconnected',
  relayLabel: null,
  lastError: null,
  logLines: [],
  recents: [],
};

const INITIAL_SPLIT_TUNNEL: SplitTunnelState = {
  enabled: true,
  bypassLan: true,
  bypassCountries: ['ir', 'cn'],
  excludedApps: [],
};

function initialState(): AppState {
  return {
    native: INITIAL_NATIVE_STATE,
    brokerUrl: AppConfig.DEFAULT_BROKER_URL,
    directoryStatus: 'idle',
    availableRegions: [],
    languageTag: '',
    homeViewMode: 'map',
    splitTunnel: INITIAL_SPLIT_TUNNEL,
    connectedAtMs: null,
    update: INITIAL_UPDATE_UI,
  };
}

let state: AppState = initialState();
const listeners = new Set<() => void>();

// Supersession token for directory loads: mirrors production's `directoryJob?.cancel()` — a
// newer (forced) refresh makes any in-flight load stale so its completion can't clobber state.
let directoryGeneration = 0;

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

/**
 * Session-uptime stamp: set on every transition INTO 'connected' (a relay
 * switch re-enters via connecting, so it restarts the clock), preserved across
 * connected-state events (log lines, recents), cleared once the tunnel leaves.
 */
function nextConnectedAtMs(previous: AppState, native: NativeVpnState): number | null {
  if (native.status !== 'connected') {
    return null;
  }
  return previous.native.status === 'connected' && previous.connectedAtMs != null
    ? previous.connectedAtMs
    : Date.now();
}

/** Mirrors a `NativeVpnState` (from getState() or an openrungStateChanged event) into the store. */
export function applyNativeState(native: NativeVpnState): void {
  setState({ ...state, native, connectedAtMs: nextConnectedAtMs(state, native) });
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
      setState({ ...state, availableRegions: regions, directoryStatus: 'loaded' });
    })
    .catch(() => {
      if (generation !== directoryGeneration) {
        return;
      }
      setState({ ...state, directoryStatus: 'failed' });
    });
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

/** Sets the home-screen directory presentation (map or list) and persists it to AsyncStorage. */
export function setHomeViewMode(mode: HomeViewMode): void {
  setState({ ...state, homeViewMode: mode });
  AsyncStorage.setItem(HOME_VIEW_MODE_STORAGE_KEY, mode).catch(() => {
    // Persistence is best-effort, same as the language selection.
  });
}

/** Loads the persisted home view mode (called once when the home screen mounts). */
export async function hydrateHomeViewMode(): Promise<void> {
  try {
    const persisted = await AsyncStorage.getItem(HOME_VIEW_MODE_STORAGE_KEY);
    if ((persisted === 'map' || persisted === 'list') && persisted !== state.homeViewMode) {
      setState({ ...state, homeViewMode: persisted });
    }
  } catch {
    // Best-effort: keep the in-memory default ('map').
  }
}

/**
 * Debounce for the native split-tunnel push: rapid toggle flips collapse into a single
 * setSplitTunnelConfig call, so a connected tunnel reapplies (tear down + reconnect) once.
 */
const SPLIT_TUNNEL_PUSH_DEBOUNCE_MS = 1200;

let splitTunnelPushTimer: ReturnType<typeof setTimeout> | null = null;

/**
 * Split-tunnel hydration is initialization, not an ongoing two-way merge with AsyncStorage.
 * Once this process has either loaded storage or accepted a local edit, the in-memory slice is
 * authoritative. The generation invalidates a read that was already in flight when a local edit
 * (or a test reset) happened; the shared promise collapses App + screen mount calls into one read.
 */
let splitTunnelGeneration = 0;
let splitTunnelHydrated = false;
let splitTunnelHydrationPromise: Promise<void> | null = null;

/**
 * Serializes the contract §3 SplitTunnelConfig JSON with the stable key order the native
 * stores rely on for their skip-reapply string comparison:
 * version, enabled, bypass_lan, bypass_countries, excluded_packages.
 */
function splitTunnelConfigJson(split: SplitTunnelState): string {
  return JSON.stringify({
    version: 1,
    enabled: split.enabled,
    bypass_lan: split.bypassLan,
    bypass_countries: split.bypassCountries,
    excluded_packages: split.excludedApps,
  });
}

function pushSplitTunnelToNative(): Promise<void> {
  // Best-effort, like the AsyncStorage writes: a failing bridge push must never break the UI.
  // The try/catch also guards the stale-APK/fresh-JS case — a native binary built before this
  // feature has no setSplitTunnelConfig method, so the call throws a synchronous TypeError the
  // trailing .catch would never see; a missing/invalid native config just degrades to full-tunnel
  // behavior.
  try {
    return Promise.resolve(
      OpenRungVpn.setSplitTunnelConfig(splitTunnelConfigJson(state.splitTunnel)),
    ).catch(() => {});
  } catch {
    return Promise.resolve();
  }
}

function scheduleSplitTunnelPush(): void {
  if (splitTunnelPushTimer != null) {
    clearTimeout(splitTunnelPushTimer);
  }
  splitTunnelPushTimer = setTimeout(() => {
    splitTunnelPushTimer = null;
    // Fire-and-forget: pushSplitTunnelToNative resolves an already-caught promise, never rejects.
    pushSplitTunnelToNative();
  }, SPLIT_TUNNEL_PUSH_DEBOUNCE_MS);
}

/**
 * Completes split-tunnel initialization, then fires any pending debounced push immediately and
 * resolves once native has persisted it. Called right before a connect so the service reads the
 * latest config in its per-connect snapshot — including the fresh-install default — rather than
 * racing the launch-time AsyncStorage read. A no-op when initialization produces no pending push.
 */
export async function flushSplitTunnelPush(): Promise<void> {
  await hydrateSplitTunnel();
  if (splitTunnelPushTimer == null) {
    return;
  }
  clearTimeout(splitTunnelPushTimer);
  splitTunnelPushTimer = null;
  await pushSplitTunnelToNative();
}

/**
 * Merges a split-tunnel patch into the state, persists it to AsyncStorage, and pushes the
 * contract §3 config JSON to the native store (debounced).
 */
export function setSplitTunnel(patch: Partial<SplitTunnelState>): void {
  // A local edit is authoritative even if the initial AsyncStorage read is still in flight.
  // Mark hydration complete and invalidate that read before changing either state or storage.
  splitTunnelGeneration++;
  splitTunnelHydrated = true;
  const splitTunnel = { ...state.splitTunnel, ...patch };
  setState({ ...state, splitTunnel });
  AsyncStorage.setItem(SPLIT_TUNNEL_STORAGE_KEY, JSON.stringify(splitTunnel)).catch(() => {
    // Persistence is best-effort, same as the language selection.
  });
  scheduleSplitTunnelPush();
}

/** Validates a persisted SplitTunnelState shape; null on anything malformed. */
function parsePersistedSplitTunnel(raw: string): SplitTunnelState | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed == null) {
    return null;
  }
  const candidate = parsed as Record<string, unknown>;
  const { enabled, bypassLan, bypassCountries, excludedApps } = candidate;
  if (typeof enabled !== 'boolean' || typeof bypassLan !== 'boolean') {
    return null;
  }
  if (!Array.isArray(bypassCountries) || !Array.isArray(excludedApps)) {
    return null;
  }
  const isString = (value: unknown): value is string => typeof value === 'string';
  return {
    enabled,
    bypassLan,
    // Only the v1-recognized countries survive hydration (unknown codes are dropped).
    bypassCountries: bypassCountries
      .filter(isString)
      .filter(code => code === 'ir' || code === 'cn'),
    excludedApps: excludedApps.filter(isString),
  };
}

/**
 * Loads the persisted split-tunnel state once, then issues ONE debounced push to native so its
 * store stays in sync after a reinstall or backup restore — the native side's string comparison
 * makes it a no-op otherwise.
 *
 * App and the split-tunneling screen can mount close together, so concurrent callers share one
 * read. A local edit always wins over storage: it invalidates an in-flight read and makes later
 * hydration calls no-ops, preventing stale storage from overwriting or being pushed over the
 * user's newer selection.
 */
export function hydrateSplitTunnel(): Promise<void> {
  if (splitTunnelHydrated) {
    return Promise.resolve();
  }
  if (splitTunnelHydrationPromise != null) {
    return splitTunnelHydrationPromise;
  }

  const generation = splitTunnelGeneration;
  let attempt: Promise<void>;
  attempt = (async () => {
    try {
      const persisted = await AsyncStorage.getItem(SPLIT_TUNNEL_STORAGE_KEY);
      if (generation !== splitTunnelGeneration) {
        return; // A local edit or reset superseded this read.
      }

      // A successful read completes initialization even when the value is absent or malformed.
      // Retrying on every screen visit would only reopen the stale-read race.
      splitTunnelHydrated = true;

      if (persisted == null) {
        // No explicit preference exists (fresh install, or an upgrade from the old default-off
        // release where untouched defaults were never persisted). Materialize the new product
        // default in both stores: split tunneling on, bypassing LAN + Iran + China. Existing users
        // with any valid saved selection — including enabled:false — take the parsed branch below
        // and keep that choice.
        await AsyncStorage.setItem(
          SPLIT_TUNNEL_STORAGE_KEY,
          JSON.stringify(state.splitTunnel),
        ).catch(() => {
          // Persistence remains best-effort; native still receives this launch's default.
        });
        scheduleSplitTunnelPush();
        return;
      }

      const parsed = parsePersistedSplitTunnel(persisted);
      if (parsed == null) {
        // Garbage is not treated like a fresh install: do not overwrite a potentially valid native
        // config when the JS-side read is corrupt. Keep the in-memory product default for this
        // launch, while native continues its fail-open behavior.
        return;
      }
      if (JSON.stringify(parsed) !== JSON.stringify(state.splitTunnel)) {
        setState({ ...state, splitTunnel: parsed });
      }
      // Sync native from RN's persisted truth (e.g. after a reinstall/backup restore where the
      // native store was cleared); the native effective-config comparison makes this a no-op when
      // the two already agree, so it never bounces a live tunnel.
      scheduleSplitTunnelPush();
    } catch {
      // Best-effort: keep the in-memory product default without overwriting native. A later caller
      // may retry because a failed read does not complete initialization.
    }
  })().finally(() => {
    if (splitTunnelHydrationPromise === attempt) {
      splitTunnelHydrationPromise = null;
    }
  });
  splitTunnelHydrationPromise = attempt;
  return attempt;
}

/** Mirrors the derived update-check UI state into the store (called by state/updateCheck.ts). */
export function applyUpdateUiState(update: UpdateUiState): void {
  setState({ ...state, update });
}

/** Test-only: resets the store to its initial state (and cancels any pending native push). */
export function resetStoreForTests(): void {
  directoryGeneration++;
  splitTunnelGeneration++;
  splitTunnelHydrated = false;
  // An old attempt cannot be cancelled, but its captured generation prevents it from applying.
  // Clear the shared slot so the reset store can start its own independent hydration.
  splitTunnelHydrationPromise = null;
  if (splitTunnelPushTimer != null) {
    clearTimeout(splitTunnelPushTimer);
    splitTunnelPushTimer = null;
  }
  state = initialState();
}
