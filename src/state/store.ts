import AsyncStorage from '@react-native-async-storage/async-storage';
import { useCallback, useRef, useSyncExternalStore } from 'react';
import { AppConfig } from '../config';
import type { DirectoryStatus, ExitNodeRegion, HomeViewMode } from '../model/exitNode';
import { bypassCountriesForRegion, deviceRegion } from '../model/splitTunnelDefaults';
import { INITIAL_UPDATE_UI, type UpdateUiState } from '../model/updateStatus';
import { firstReachable } from '../net/brokerClient';
import { loadExitNodeDirectory } from '../net/exitNodeDirectory';
import { OpenRungVpn } from '../native/OpenRungVpn';
import type { NativeVpnState, RecentNode } from '../native/types';

/**
 * Minimal external store holding the contract §4 AppState (mirrors the production
 * `OpenRungUiState`): the native slice is mirrored from `OpenRungVpn` events; the directory slice
 * reproduces `OpenRungStatusStore.refreshDirectory`.
 */

export interface SplitTunnelState {
  enabled: boolean;
  bypassLan: boolean;
  /**
   * Lowercase ISO codes; v1 recognizes only 'ir' and 'cn', and holds AT MOST ONE of them. The
   * presets describe where the device is, and no device is in two countries at once: enabling
   * both only adds a whole country's domains to the direct path where they cannot help — which
   * is exactly the leak the region-derived default exists to avoid. Stays an array because the
   * native contract field is a list (§3) and native parsers remain tolerant of several.
   */
  bypassCountries: string[];
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
/**
 * Split-tunnel selections are session-scoped and NOT persisted, so nothing writes this key any
 * more. It survives only so `initializeSplitTunnel` can delete what older builds left behind.
 */
export const SPLIT_TUNNEL_STORAGE_KEY = 'openrung.splitTunnel';

const INITIAL_NATIVE_STATE: NativeVpnState = {
  status: 'disconnected',
  relayLabel: null,
  relayName: null,
  relayClass: null,
  lastError: null,
  logLines: [],
  recents: [],
};

/**
 * The device region the current country selection was derived from, or null once the user has
 * picked countries by hand.
 *
 * This is what separates "we guessed this for you" from "you chose this", and the difference is
 * load-bearing: an automatic selection must follow the device, because a phone that auto-selected
 * `['cn']` in Shanghai and is now in Berlin would otherwise keep pushing geosite-cn (gstatic,
 * doubleclick, fonts.googleapis.com …) onto the direct path forever. A deliberate choice must
 * never be second-guessed, however far the user travels. Persisted alongside the slice.
 */
let splitTunnelAutoRegion: string | null = null;

/**
 * Fresh-install split-tunnel defaults: master on, LAN bypassed, and a country preset ONLY on a
 * device that is actually in that country (see model/splitTunnelDefaults — geosite-cn outside
 * China would push ordinary Google/CDN hosts onto the direct path).
 *
 * Records the region it derived from as it goes: the two must never disagree, and doing it here
 * means no caller can create a selection without its provenance.
 */
function initialSplitTunnel(): SplitTunnelState {
  splitTunnelAutoRegion = deviceRegion();
  return {
    enabled: true,
    bypassLan: true,
    bypassCountries: bypassCountriesForRegion(splitTunnelAutoRegion),
    excludedApps: [],
  };
}

function initialState(): AppState {
  return {
    native: INITIAL_NATIVE_STATE,
    brokerUrl: AppConfig.DEFAULT_BROKER_URL,
    directoryStatus: 'idle',
    availableRegions: [],
    languageTag: '',
    homeViewMode: 'map',
    splitTunnel: initialSplitTunnel(),
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

/** React hook over the external store. Subscribes to EVERY store change — prefer
 * `useAppSelector` in components, so a native event (e.g. a debug log line) only re-renders
 * consumers whose selected slice actually changed. */
export function useAppState(): AppState {
  return useSyncExternalStore(subscribe, getSnapshot);
}

/** Shallow equality over primitives, arrays (element-wise) and plain objects (own keys). */
function shallowEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) {
    return true;
  }
  if (typeof a !== 'object' || a == null || typeof b !== 'object' || b == null) {
    return false;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    return (
      Array.isArray(a) &&
      Array.isArray(b) &&
      a.length === b.length &&
      a.every((value, index) => Object.is(value, b[index]))
    );
  }
  const keysA = Object.keys(a);
  const keysB = Object.keys(b);
  return (
    keysA.length === keysB.length &&
    keysA.every(
      key =>
        Object.prototype.hasOwnProperty.call(b, key) &&
        Object.is((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key]),
    )
  );
}

/**
 * Subscribes to the slice a component actually renders. The selected value is cached per hook:
 * while the freshly selected value stays shallow-equal, the previous reference is returned and
 * React bails out of the re-render. This is what keeps high-frequency native events (log lines
 * during a connect) from re-rendering the map/tab tree.
 */
export function useAppSelector<T>(
  selector: (current: AppState) => T,
  isEqual: (a: T, b: T) => boolean = shallowEqual,
): T {
  const cacheRef = useRef<{ snapshot: AppState; selected: T } | null>(null);
  // Latest selector/equality without re-subscribing (the standard external-store shim pattern).
  const selectorRef = useRef(selector);
  const isEqualRef = useRef(isEqual);
  selectorRef.current = selector;
  isEqualRef.current = isEqual;

  const getSelected = useCallback((): T => {
    const snapshot = getSnapshot();
    const cache = cacheRef.current;
    if (cache !== null && cache.snapshot === snapshot) {
      return cache.selected;
    }
    const next = selectorRef.current(snapshot);
    const selected =
      cache !== null && isEqualRef.current(cache.selected, next) ? cache.selected : next;
    cacheRef.current = { snapshot, selected };
    return selected;
  }, []);

  return useSyncExternalStore(subscribe, getSelected);
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

function sameRecent(a: RecentNode, b: RecentNode): boolean {
  return (
    a.countryCode === b.countryCode &&
    a.relayId === b.relayId &&
    a.label === b.label &&
    a.relayName === b.relayName &&
    a.latitude === b.latitude &&
    a.longitude === b.longitude
  );
}

/**
 * Every bridge event materializes fresh arrays even when their content did not change. Reuse the
 * previous references for content-equal `logLines`/`recents` (and the whole native slice when the
 * event is a no-op) so `useAppSelector`'s shallow comparison can skip re-renders.
 */
function stabilizedNative(previous: NativeVpnState, next: NativeVpnState): NativeVpnState {
  const logLines =
    previous.logLines.length === next.logLines.length &&
    next.logLines.every((line, index) => line === previous.logLines[index])
      ? previous.logLines
      : next.logLines;
  const recents =
    previous.recents.length === next.recents.length &&
    next.recents.every((node, index) => sameRecent(node, previous.recents[index]))
      ? previous.recents
      : next.recents;
  if (
    logLines === previous.logLines &&
    recents === previous.recents &&
    previous.status === next.status &&
    previous.relayLabel === next.relayLabel &&
    previous.relayName === next.relayName &&
    previous.relayClass === next.relayClass &&
    previous.lastError === next.lastError
  ) {
    return previous;
  }
  return { ...next, logLines, recents };
}

/** Mirrors a `NativeVpnState` (from getState() or an openrungStateChanged event) into the store. */
export function applyNativeState(native: NativeVpnState): void {
  // A stale native binary (built before relayClass existed) omits the field, and the bridge
  // payload is untyped at runtime — collapse anything but the two contract values to null so
  // the store always holds a valid NativeVpnState.
  const relayClass =
    native.relayClass === 'foundation' || native.relayClass === 'volunteer'
      ? native.relayClass
      : null;
  const stabilized = stabilizedNative(state.native, { ...native, relayClass });
  const connectedAtMs = nextConnectedAtMs(state, stabilized);
  if (stabilized === state.native && connectedAtMs === state.connectedAtMs) {
    return; // content-identical event — nothing to publish
  }
  setState({ ...state, native: stabilized, connectedAtMs });
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

  return loadExitNodeDirectory({
    fetchRelays: async () => {
      const identity = await OpenRungVpn.getIdentity();
      return (
        await firstReachable(current.brokerUrl, {
          limit: AppConfig.DIRECTORY_RELAY_LIMIT,
          clientId: identity.clientId,
          sessionId: identity.sessionId,
        })
      ).response;
    },
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
 * Split-tunnel selections are SESSION-SCOPED: every launch starts from the product default
 * (`initialSplitTunnel`) and a user's changes last only as long as this JS process. Nothing about
 * the slice is persisted on the RN side, so there is no stored preference to load, merge, or
 * migrate — the in-memory slice is authoritative for the whole session.
 *
 * The shared promise collapses the App + screen mount calls into one initialization.
 */
let splitTunnelInitialized = false;
let splitTunnelInitializationPromise: Promise<void> | null = null;

/**
 * Serializes the contract §3 SplitTunnelConfig JSON with the stable key order the native
 * stores rely on for their skip-reapply string comparison:
 * version, enabled, bypass_lan, bypass_countries, country_source, excluded_packages.
 */
function splitTunnelConfigJson(split: SplitTunnelState): string {
  return JSON.stringify({
    version: 1,
    enabled: split.enabled,
    bypass_lan: split.bypassLan,
    bypass_countries: split.bypassCountries,
    // Provenance, not a preference. `bypass_countries` is a snapshot taken whenever JS last ran;
    // `country_source: "auto"` tells native to re-derive it from the device's OWN time zone every
    // time it builds a config — including the background recovery rebuilds after a physical
    // network change, which no JS code participates in. Without this a phone that auto-selected
    // China in Shanghai could have its tunnel rebuilt with geosite-cn bypassed in Berlin, before
    // the user ever opens the app.
    country_source: splitTunnelAutoRegion === null ? 'manual' : 'auto',
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
 * resolves once native has persisted it. Called right before a connect so the service reads this
 * session's config in its per-connect snapshot — including the launch default, which must land
 * before the first connect of a session that has replaced the previous session's edits.
 */
export async function flushSplitTunnelPush(): Promise<void> {
  await initializeSplitTunnel();
  // Also re-check the region here: within one long-lived session the device can move, and this
  // runs immediately before the connect that would otherwise carry a stale country preset onto
  // the direct path.
  refreshSplitTunnelRegion();
  if (splitTunnelPushTimer == null) {
    return;
  }
  clearTimeout(splitTunnelPushTimer);
  splitTunnelPushTimer = null;
  await pushSplitTunnelToNative();
}

/**
 * Re-checks an AUTOMATIC country selection against where the device is now, re-deriving it (and
 * pushing) when the device has moved. One Intl read and a no-op in every normal case.
 *
 * The launch default already reflects the region, so this only matters within a session that
 * outlives a move — the JS process routinely survives a flight, suspended in Shanghai and resumed
 * in Berlin. It runs on every app foreground (App.tsx) and immediately before every connect
 * (`flushSplitTunnelPush`). Native re-derives independently on every config build (contract §3
 * `country_source`), so this keeps the displayed toggles honest rather than being the only guard.
 */
export function refreshSplitTunnelRegion(): void {
  if (splitTunnelAutoRegion === null) {
    return; // The user chose these countries by hand; travelling must never undo that.
  }
  const region = deviceRegion();
  if (region === splitTunnelAutoRegion) {
    return;
  }
  splitTunnelAutoRegion = region;
  const bypassCountries = bypassCountriesForRegion(region);
  if (!shallowEqual(bypassCountries, state.splitTunnel.bypassCountries)) {
    setState({ ...state, splitTunnel: { ...state.splitTunnel, bypassCountries } });
  }
  scheduleSplitTunnelPush();
}

/**
 * Merges a split-tunnel patch into the state, persists it to AsyncStorage, and pushes the
 * contract §3 config JSON to the native store (debounced).
 */
export function setSplitTunnel(patch: Partial<SplitTunnelState>): void {
  if (patch.bypassCountries !== undefined) {
    // The user set the countries themselves, so they stop tracking the device region — travelling
    // must never undo a deliberate choice. Only a country edit forfeits automatic tracking;
    // toggling LAN or apps says nothing about which country's rule set belongs here.
    splitTunnelAutoRegion = null;
  }
  const splitTunnel = { ...state.splitTunnel, ...patch };
  setState({ ...state, splitTunnel });
  // Deliberately not persisted: the edit lasts for this session only (see
  // splitTunnelInitialized). Native still receives it, because the VPN service reads its own
  // store at connect time and must route this session the way the user just asked.
  scheduleSplitTunnelPush();
}

/**
 * Materializes this session's split-tunnel config: pushes the launch default to native and drops
 * the preferences key older builds persisted. Idempotent — App and the split-tunneling screen can
 * mount close together, and they share one initialization.
 *
 * There is nothing to load. The slice already holds this launch's default (`initialSplitTunnel`),
 * and by design no earlier selection is restored: a user's changes last only while the app is
 * open. What DOES need doing is telling native, because its store still holds whatever the
 * previous session pushed and the VPN service reads that store on every connect — including the
 * background recovery rebuilds it performs on its own. Pushing here is what makes "reopening the
 * app returns to the default" true for routing and not just for the toggles on screen.
 *
 * A live tunnel whose config differed from the default therefore reapplies (a brief reconnect)
 * shortly after launch. That is the intended consequence of session-scoped settings.
 */
export function initializeSplitTunnel(): Promise<void> {
  // Promise first: `splitTunnelInitialized` is set synchronously below, so checking it first
  // would make concurrent callers miss the shared attempt and never await the cleanup.
  if (splitTunnelInitializationPromise != null) {
    return splitTunnelInitializationPromise;
  }
  if (splitTunnelInitialized) {
    return Promise.resolve();
  }
  splitTunnelInitialized = true;

  // Push before the cleanup: the config reaching native is what matters, and the removal is
  // housekeeping that must never delay or block it.
  scheduleSplitTunnelPush();

  let attempt: Promise<void>;
  attempt = AsyncStorage.removeItem(SPLIT_TUNNEL_STORAGE_KEY)
    .catch(() => {
      // Best-effort. A key left behind is inert — nothing reads it any more.
    })
    .finally(() => {
      if (splitTunnelInitializationPromise === attempt) {
        splitTunnelInitializationPromise = null;
      }
    });
  splitTunnelInitializationPromise = attempt;
  return attempt;
}

/** Mirrors the derived update-check UI state into the store (called by state/updateCheck.ts). */
export function applyUpdateUiState(update: UpdateUiState): void {
  setState({ ...state, update });
}

/** Test-only: resets the store to its initial state (and cancels any pending native push). */
export function resetStoreForTests(): void {
  directoryGeneration++;
  splitTunnelInitialized = false;
  // An old attempt cannot be cancelled; clearing the slot lets the reset store initialize again.
  splitTunnelInitializationPromise = null;
  if (splitTunnelPushTimer != null) {
    clearTimeout(splitTunnelPushTimer);
    splitTunnelPushTimer = null;
  }
  state = initialState();
}
