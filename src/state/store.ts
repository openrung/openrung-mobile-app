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
 * Revision of the shipped defaults the persisted slice was written under. Bumped only when a
 * default changes in a way that must also repair installs which already materialized the old
 * one; `repairShippedCountryDefaults` reads it. Revision 1 is implicit — it is what every write
 * before region-aware defaults produced.
 */
const SPLIT_TUNNEL_DEFAULTS_REVISION = 2;

/** The persisted slice plus the metadata describing where its country selection came from. */
interface PersistedSplitTunnel {
  splitTunnel: SplitTunnelState;
  defaultsRevision: number;
  /** Region the countries were auto-derived from; null when the user picked them. */
  autoCountryRegion: string | null;
}

/** Best-effort persistence of the slice, stamped with the metadata hydration needs to interpret it. */
function persistSplitTunnel(splitTunnel: SplitTunnelState): Promise<void> {
  return AsyncStorage.setItem(
    SPLIT_TUNNEL_STORAGE_KEY,
    JSON.stringify({
      ...splitTunnel,
      defaultsRevision: SPLIT_TUNNEL_DEFAULTS_REVISION,
      autoCountryRegion: splitTunnelAutoRegion,
    }),
  ).catch(() => {
    // Persistence is best-effort, same as the language selection.
  });
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
  if (patch.bypassCountries !== undefined) {
    // The user set the countries themselves, so they stop tracking the device region — travelling
    // must never undo a deliberate choice. Only a country edit forfeits automatic tracking;
    // toggling LAN or apps says nothing about which country's rule set belongs here.
    splitTunnelAutoRegion = null;
  }
  const splitTunnel = { ...state.splitTunnel, ...patch };
  setState({ ...state, splitTunnel });
  persistSplitTunnel(splitTunnel);
  scheduleSplitTunnelPush();
}

/**
 * Collapses a country list to the single preset the exclusivity invariant allows. The screen only
 * ever writes one, so a pair can only arrive from an install that predates the invariant (or from
 * a hand-edited value): keep the one matching where the device is, else the first listed. Never
 * both, so a legacy pair can't re-enter the emitted config through hydration.
 */
function soleCountry(countries: string[], region: string): string[] {
  if (countries.length <= 1) {
    return countries;
  }
  const [local] = bypassCountriesForRegion(region);
  return local != null && countries.includes(local) ? [local] : countries.slice(0, 1);
}

/** Validates a persisted SplitTunnelState shape; null on anything malformed. */
function parsePersistedSplitTunnel(raw: string): PersistedSplitTunnel | null {
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
  const { enabled, bypassLan, bypassCountries, excludedApps, defaultsRevision, autoCountryRegion } =
    candidate;
  if (typeof enabled !== 'boolean' || typeof bypassLan !== 'boolean') {
    return null;
  }
  if (!Array.isArray(bypassCountries) || !Array.isArray(excludedApps)) {
    return null;
  }
  const isString = (value: unknown): value is string => typeof value === 'string';
  return {
    splitTunnel: {
      enabled,
      bypassLan,
      // Only the v1-recognized countries survive hydration (unknown codes are dropped). The
      // exclusivity invariant is applied later, by normalizeHydratedSplitTunnel.
      bypassCountries: bypassCountries
        .filter(isString)
        .filter(code => code === 'ir' || code === 'cn'),
      excludedApps: excludedApps.filter(isString),
    },
    // Anything written before region-aware defaults carries no revision at all.
    defaultsRevision: typeof defaultsRevision === 'number' ? defaultsRevision : 1,
    // Absent means "not known to be automatic" — the conservative reading, since treating a
    // deliberate choice as automatic would let a later move overwrite it. The revision-1 repair
    // below re-establishes provenance for the one selection we know was machine-made.
    autoCountryRegion: typeof autoCountryRegion === 'string' ? autoCountryRegion : null,
  };
}

/**
 * Settles the country presets of a hydrated slice and re-establishes their provenance. Three
 * passes, in this order — collapsing first would destroy the exact pair the repair keys on.
 *
 * REPAIR: the revision-1 default materialized bypassCountries ['ir', 'cn'] on EVERY install
 * regardless of where the device was, so outside Iran and China the geosite-cn set — which
 * carries hosts the whole world loads on ordinary pages (doubleclick.net, fonts.googleapis.com,
 * www.gstatic.com …) — sent those requests out on the direct path with the user's real IP while
 * the app reported CONNECTED. Any config whose countries are exactly that pair is re-derived from
 * the device region, INCLUDING a disabled one: `enabled` says whether split tunneling is running,
 * not where the countries came from, and leaving a stale pair parked behind an off switch just
 * arms the same leak for whenever the user flips it back on. A user who deliberately picked
 * exactly ir+cn is indistinguishable from the untouched default and gets re-defaulted once — the
 * safe direction, and both toggles are one tap away.
 *
 * REFRESH: an automatic selection follows the device. If the region it was derived from is no
 * longer where the device is — the user moved, or a wrong time zone got corrected — it is
 * re-derived. Without this, a phone that auto-selected ['cn'] in Shanghai keeps bypassing
 * geosite-cn forever once it lands in Berlin, which is the original leak with extra steps. A
 * selection the user made by hand (autoCountryRegion null) is never touched.
 *
 * EXCLUSIVITY: whatever survives collapses to a single preset, catching pairs neither earlier
 * pass claimed (e.g. one saved under the current revision).
 */
function normalizeHydratedSplitTunnel(persisted: PersistedSplitTunnel): SplitTunnelState {
  const { splitTunnel, defaultsRevision, autoCountryRegion } = persisted;
  const { bypassCountries } = splitTunnel;
  const region = deviceRegion();

  const isShippedDefault =
    defaultsRevision < SPLIT_TUNNEL_DEFAULTS_REVISION &&
    bypassCountries.length === 2 &&
    bypassCountries.includes('ir') &&
    bypassCountries.includes('cn');
  const isStaleAutomatic = autoCountryRegion !== null && autoCountryRegion !== region;

  if (isShippedDefault || isStaleAutomatic) {
    splitTunnelAutoRegion = region;
    return { ...splitTunnel, bypassCountries: bypassCountriesForRegion(region) };
  }

  splitTunnelAutoRegion = autoCountryRegion;
  const countries = soleCountry(bypassCountries, region);
  return countries === bypassCountries
    ? splitTunnel
    : { ...splitTunnel, bypassCountries: countries };
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
        // release where untouched defaults were never persisted). Materialize the product default
        // in both stores: split tunneling on, bypassing LAN plus whichever country preset matches
        // where the device is. Existing users with any valid saved selection — including
        // enabled:false — take the parsed branch below and keep that choice.
        await persistSplitTunnel(state.splitTunnel);
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
      const splitTunnel = normalizeHydratedSplitTunnel(parsed);
      if (JSON.stringify(splitTunnel) !== JSON.stringify(state.splitTunnel)) {
        setState({ ...state, splitTunnel });
      }
      if (
        parsed.defaultsRevision < SPLIT_TUNNEL_DEFAULTS_REVISION ||
        splitTunnel !== parsed.splitTunnel ||
        splitTunnelAutoRegion !== parsed.autoCountryRegion
      ) {
        // Write back whenever this pass changed anything storage records: the revision stamp, a
        // repaired/refreshed/collapsed country list, or the provenance that decides whether the
        // next launch may re-derive it. Otherwise storage and state disagree and the same work
        // repeats on every launch.
        await persistSplitTunnel(splitTunnel);
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
