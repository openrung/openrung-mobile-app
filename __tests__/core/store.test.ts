/**
 * refreshDirectory no-op semantics (production OpenRungStatusStore.refreshDirectory):
 * no-op while a load is in flight or after a successful NON-EMPTY load, unless forced.
 * Also covers the persisted homeViewMode preference (map/list home presentation) and the
 * splitTunnel slice (persisted state + the debounced setSplitTunnelConfig push to native).
 */
jest.mock('@react-native-async-storage/async-storage', () => {
  const storage = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (key: string) => storage.get(key) ?? null),
      setItem: jest.fn(async (key: string, value: string) => {
        storage.set(key, value);
      }),
      removeItem: jest.fn(async (key: string) => {
        storage.delete(key);
      }),
    },
  };
});

const mockFirstReachable = jest.fn();

jest.mock('../../src/net/brokerClient', () => ({
  firstReachable: (...args: unknown[]) => mockFirstReachable(...args),
}));

// Which country presets a fresh install starts with depends on where the device is, which is
// host state (Intl time zone). Pin it so the defaults are deterministic, and let the tests that
// care place the device explicitly.
jest.mock('../../src/model/splitTunnelDefaults', () => ({
  defaultBypassCountries: jest.fn(() => [] as string[]),
}));

// The store reads its paired native identity before directory selection and pushes split-tunnel
// configs through the OpenRungVpn bridge. Keep both operations deterministic and hostless.
jest.mock('../../src/native/OpenRungVpn', () => ({
  OpenRungVpn: {
    getIdentity: jest.fn(async () => ({
      clientId: 'client-directory',
      sessionId: 'session-directory',
    })),
    setSplitTunnelConfig: jest.fn(async () => {}),
  },
}));

import AsyncStorage from '@react-native-async-storage/async-storage';

import { AppConfig } from '../../src/config';
import { defaultBypassCountries } from '../../src/model/splitTunnelDefaults';
import { OpenRungVpn } from '../../src/native/OpenRungVpn';
import {
  HOME_VIEW_MODE_STORAGE_KEY,
  SPLIT_TUNNEL_STORAGE_KEY,
  applyNativeState,
  getSnapshot,
  hydrateHomeViewMode,
  hydrateSplitTunnel,
  flushSplitTunnelPush,
  refreshDirectory,
  resetStoreForTests,
  setHomeViewMode,
  setSplitTunnel,
} from '../../src/state/store';
import type { NativeVpnState } from '../../src/native/types';

const RELAY_LIST = {
  count: 1,
  server_time: '2026-01-01T00:00:00Z',
  relays: [
    {
      id: 'tokyo-relay-1',
      public_host: '203.0.113.10',
      public_port: 443,
      // Broker-served exit location — the app never geolocates relay IPs itself.
      city: 'Tokyo',
      country: 'Japan',
      country_code: 'JP',
      latitude: 35.6895,
      longitude: 139.6917,
      protocol: 'vless-reality-vision',
      client_id: 'e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f',
      reality_public_key: 'pubkey',
      short_id: 'abcd',
      server_name: 'www.example.com',
      flow: 'xtls-rprx-vision',
      exit_mode: 'direct',
      max_sessions: 8,
      max_mbps: 100,
      volunteer_version: '1.0.0',
      registered_at: '2025-12-31T00:00:00Z',
      last_heartbeat_at: '2025-12-31T23:59:00Z',
      expires_at: '2026-01-01T01:00:00Z',
    },
  ],
};

function installNativeDirectory(relayPayload: unknown = RELAY_LIST): void {
  mockFirstReachable.mockReset();
  mockFirstReachable.mockResolvedValue({
    brokerUrl: AppConfig.DEFAULT_BROKER_URL,
    response: relayPayload,
  });
}

beforeEach(() => {
  resetStoreForTests();
  (OpenRungVpn.getIdentity as jest.Mock).mockClear();
  installNativeDirectory();
});

describe('refreshDirectory', () => {
  it('loads the directory: usable relays grouped by broker-served location at broker coordinates', async () => {
    await refreshDirectory();
    const state = getSnapshot();
    expect(state.directoryStatus).toBe('loaded');
    expect(state.availableRegions).toEqual([
      {
        countryCode: 'JP',
        countryName: 'Japan',
        city: 'Tokyo',
        latitude: 35.6895, // the broker's coordinate, no client-side geo lookup
        longitude: 139.6917,
        nodeCount: 1,
        // No node_class in the fixture -> the volunteer default, like older brokers.
        relays: [{ id: 'tokyo-relay-1', label: null, nodeClass: 'volunteer' }],
      },
    ]);
    expect(OpenRungVpn.getIdentity).toHaveBeenCalledTimes(1);
    expect(mockFirstReachable).toHaveBeenCalledWith(AppConfig.DEFAULT_BROKER_URL, {
      limit: AppConfig.DIRECTORY_RELAY_LIMIT,
      clientId: 'client-directory',
      sessionId: 'session-directory',
    });
  });

  it('is a no-op after a successful non-empty load', async () => {
    await refreshDirectory();
    expect(mockFirstReachable).toHaveBeenCalledTimes(1);
    await refreshDirectory();
    expect(mockFirstReachable).toHaveBeenCalledTimes(1); // unchanged
    expect(getSnapshot().directoryStatus).toBe('loaded');
  });

  it('reloads when forced', async () => {
    await refreshDirectory();
    expect(mockFirstReachable).toHaveBeenCalledTimes(1);
    await refreshDirectory(true);
    expect(mockFirstReachable).toHaveBeenCalledTimes(2);
    expect(getSnapshot().directoryStatus).toBe('loaded');
  });

  it('is a no-op while a load is already in flight', async () => {
    const first = refreshDirectory();
    expect(getSnapshot().directoryStatus).toBe('loading');
    const second = refreshDirectory(); // resolves immediately without fetching
    await Promise.all([first, second]);
    expect(mockFirstReachable).toHaveBeenCalledTimes(1);
  });

  it('re-fetches after a load that returned no regions (loaded-but-empty is not "already loaded")', async () => {
    installNativeDirectory({ count: 0, server_time: '2026-01-01T00:00:00Z', relays: [] });
    await refreshDirectory();
    expect(getSnapshot().directoryStatus).toBe('loaded');
    expect(getSnapshot().availableRegions).toEqual([]);
    await refreshDirectory(); // no force needed: empty load must not latch
    expect(mockFirstReachable).toHaveBeenCalledTimes(2);
  });

  it('marks the directory failed when every broker candidate fails, then allows a retry', async () => {
    mockFirstReachable.mockRejectedValue(new Error('network down'));
    await refreshDirectory();
    expect(getSnapshot().directoryStatus).toBe('failed');

    installNativeDirectory();
    await refreshDirectory(); // FAILED does not latch either
    expect(getSnapshot().directoryStatus).toBe('loaded');
    expect(getSnapshot().availableRegions).toHaveLength(1);
  });
});

describe('homeViewMode', () => {
  beforeEach(async () => {
    await AsyncStorage.removeItem(HOME_VIEW_MODE_STORAGE_KEY);
  });

  it('defaults to the map presentation', () => {
    expect(getSnapshot().homeViewMode).toBe('map');
  });

  it('setHomeViewMode updates the state and persists the selection', async () => {
    setHomeViewMode('list');
    expect(getSnapshot().homeViewMode).toBe('list');
    expect(await AsyncStorage.getItem(HOME_VIEW_MODE_STORAGE_KEY)).toBe('list');
  });

  it('hydrates a persisted selection', async () => {
    await AsyncStorage.setItem(HOME_VIEW_MODE_STORAGE_KEY, 'list');
    await hydrateHomeViewMode();
    expect(getSnapshot().homeViewMode).toBe('list');
  });

  it('ignores unknown persisted values', async () => {
    await AsyncStorage.setItem(HOME_VIEW_MODE_STORAGE_KEY, 'globe');
    await hydrateHomeViewMode();
    expect(getSnapshot().homeViewMode).toBe('map');
  });
});

describe('splitTunnel', () => {
  const mockSetSplitTunnelConfig = OpenRungVpn.setSplitTunnelConfig as jest.Mock;
  const mockGetItem = AsyncStorage.getItem as jest.Mock;
  const mockDefaultCountries = defaultBypassCountries as jest.Mock;

  /** The default on a device that is neither in Iran nor in China: LAN bypass only. */
  const DEFAULT_SPLIT_TUNNEL = {
    enabled: true,
    bypassLan: true,
    bypassCountries: [],
    excludedApps: [],
  };

  /** What `setSplitTunnel`/hydration actually write: the slice plus the defaults-revision stamp. */
  const persistedJson = (splitTunnel: object, defaultsRevision = 2): string =>
    JSON.stringify({ ...splitTunnel, defaultsRevision });

  /** A pre-region-aware write: the shipped ir+cn default, with no revision stamp. */
  const LEGACY_DEFAULT_JSON = JSON.stringify({
    enabled: true,
    bypassLan: true,
    bypassCountries: ['ir', 'cn'],
    excludedApps: [],
  });

  beforeEach(async () => {
    await AsyncStorage.removeItem(SPLIT_TUNNEL_STORAGE_KEY);
    mockGetItem.mockClear();
    mockSetSplitTunnelConfig.mockClear();
    // Outside Iran and China unless a test places the device somewhere else; re-derive the
    // initial slice so the change takes effect.
    mockDefaultCountries.mockReturnValue([]);
    resetStoreForTests();
    jest.useFakeTimers();
  });

  afterEach(() => {
    resetStoreForTests(); // cancels any pending debounced push before real timers return
    jest.useRealTimers();
  });

  it('defaults to enabled with LAN bypass and no country preset outside Iran and China', () => {
    expect(getSnapshot().splitTunnel).toEqual(DEFAULT_SPLIT_TUNNEL);
  });

  it('defaults to the local country preset on a device inside Iran or China', () => {
    mockDefaultCountries.mockReturnValue(['ir']);
    resetStoreForTests();
    expect(getSnapshot().splitTunnel).toEqual({ ...DEFAULT_SPLIT_TUNNEL, bypassCountries: ['ir'] });

    mockDefaultCountries.mockReturnValue(['cn']);
    resetStoreForTests();
    expect(getSnapshot().splitTunnel).toEqual({ ...DEFAULT_SPLIT_TUNNEL, bypassCountries: ['cn'] });
  });

  it('setSplitTunnel merges, persists, and pushes the contract JSON after the debounce', async () => {
    setSplitTunnel({ enabled: true, bypassCountries: ['ir'] });
    expect(getSnapshot().splitTunnel).toEqual({
      enabled: true,
      bypassLan: true,
      bypassCountries: ['ir'],
      excludedApps: [],
    });
    expect(await AsyncStorage.getItem(SPLIT_TUNNEL_STORAGE_KEY)).toBe(
      persistedJson(getSnapshot().splitTunnel),
    );

    // The native push waits out the debounce, then sends the §1 JSON with the stable
    // key order the native stores compare against verbatim.
    expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":[]}',
    );
  });

  it('collapses rapid changes into a single debounced push of the final state', () => {
    setSplitTunnel({ enabled: true, bypassCountries: ['ir', 'cn'] });
    jest.advanceTimersByTime(600);
    setSplitTunnel({ bypassLan: false });
    jest.advanceTimersByTime(1199);
    expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();

    jest.advanceTimersByTime(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["ir","cn"],"excluded_packages":[]}',
    );
  });

  it('hydrates a persisted state and re-syncs native with one debounced push', async () => {
    await AsyncStorage.setItem(
      SPLIT_TUNNEL_STORAGE_KEY,
      JSON.stringify({
        enabled: true,
        bypassLan: false,
        bypassCountries: ['cn'],
        excludedApps: ['com.tencent.mm'],
      }),
    );
    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel).toEqual({
      enabled: true,
      bypassLan: false,
      bypassCountries: ['cn'],
      excludedApps: ['com.tencent.mm'],
    });

    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["cn"],"excluded_packages":["com.tencent.mm"]}',
    );
  });

  it('preserves an explicitly saved disabled selection', async () => {
    await AsyncStorage.setItem(
      SPLIT_TUNNEL_STORAGE_KEY,
      JSON.stringify({
        enabled: false,
        bypassLan: false,
        bypassCountries: ['cn'],
        excludedApps: [],
      }),
    );

    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel).toEqual({
      enabled: false,
      bypassLan: false,
      bypassCountries: ['cn'],
      excludedApps: [],
    });

    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":false,"bypass_lan":false,"bypass_countries":["cn"],"excluded_packages":[]}',
    );
  });

  it('does not let a delayed hydration overwrite or push over a newer user edit', async () => {
    let resolveRead: ((value: string | null) => void) | undefined;
    const delayedRead = new Promise<string | null>(resolve => {
      resolveRead = resolve;
    });
    mockGetItem.mockImplementationOnce(() => delayedRead);

    const hydration = hydrateSplitTunnel();
    expect(mockGetItem).toHaveBeenCalledTimes(1);

    // The user changes the config while AsyncStorage still holds/returns the old selection.
    setSplitTunnel({ enabled: true, bypassCountries: ['cn'] });
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenLastCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],"excluded_packages":[]}',
    );

    resolveRead?.(
      JSON.stringify({
        enabled: false,
        bypassLan: false,
        bypassCountries: ['ir'],
        excludedApps: ['stale.package'],
      }),
    );
    await hydration;
    jest.advanceTimersByTime(1200);

    expect(getSnapshot().splitTunnel).toEqual({
      enabled: true,
      bypassLan: true,
      bypassCountries: ['cn'],
      excludedApps: [],
    });
    // Completing the stale read neither schedules a second push nor replaces the latest payload.
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
  });

  it('coalesces concurrent hydration calls into one read and one native sync', async () => {
    let resolveRead: ((value: string | null) => void) | undefined;
    const delayedRead = new Promise<string | null>(resolve => {
      resolveRead = resolve;
    });
    mockGetItem.mockImplementationOnce(() => delayedRead);

    const first = hydrateSplitTunnel();
    const second = hydrateSplitTunnel();
    expect(second).toBe(first);
    expect(mockGetItem).toHaveBeenCalledTimes(1);

    resolveRead?.(
      JSON.stringify({
        enabled: true,
        bypassLan: false,
        bypassCountries: ['ir'],
        excludedApps: [],
      }),
    );
    await Promise.all([first, second]);
    expect(getSnapshot().splitTunnel).toEqual({
      enabled: true,
      bypassLan: false,
      bypassCountries: ['ir'],
      excludedApps: [],
    });

    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
  });

  it('treats a local edit made before hydration as authoritative', async () => {
    setSplitTunnel({ enabled: true, bypassCountries: ['ir'] });

    await hydrateSplitTunnel();
    expect(mockGetItem).not.toHaveBeenCalled();
    expect(getSnapshot().splitTunnel).toEqual({
      enabled: true,
      bypassLan: true,
      bypassCountries: ['ir'],
      excludedApps: [],
    });

    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenLastCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":[]}',
    );
  });

  it('persists and pushes the enabled bypass defaults when no preference exists', async () => {
    await hydrateSplitTunnel();
    expect(await AsyncStorage.getItem(SPLIT_TUNNEL_STORAGE_KEY)).toBe(
      persistedJson(DEFAULT_SPLIT_TUNNEL),
    );

    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":[],"excluded_packages":[]}',
    );
  });

  it('flushes fresh-install initialization before the first native connect can start', async () => {
    mockDefaultCountries.mockReturnValue(['cn']);
    resetStoreForTests();

    await flushSplitTunnelPush();

    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],"excluded_packages":[]}',
    );
  });

  it('re-derives the shipped ir+cn default on upgrade, from where the device actually is', async () => {
    // Every 0.3.x install materialized ir+cn regardless of location, so geosite-cn (gstatic,
    // doubleclick, fonts.googleapis.com …) escaped onto the direct path worldwide.
    await AsyncStorage.setItem(SPLIT_TUNNEL_STORAGE_KEY, LEGACY_DEFAULT_JSON);

    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel).toEqual(DEFAULT_SPLIT_TUNNEL);
    // The repair is stamped, so it happens exactly once.
    expect(await AsyncStorage.getItem(SPLIT_TUNNEL_STORAGE_KEY)).toBe(
      persistedJson(DEFAULT_SPLIT_TUNNEL),
    );

    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":[],"excluded_packages":[]}',
    );
  });

  it('keeps the local preset when repairing on a device inside Iran', async () => {
    mockDefaultCountries.mockReturnValue(['ir']);
    await AsyncStorage.setItem(SPLIT_TUNNEL_STORAGE_KEY, LEGACY_DEFAULT_JSON);

    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['ir']);
  });

  it('never re-derives an ir+cn selection that was made after the repair', async () => {
    await AsyncStorage.setItem(
      SPLIT_TUNNEL_STORAGE_KEY,
      persistedJson({
        enabled: true,
        bypassLan: true,
        bypassCountries: ['ir', 'cn'],
        excludedApps: [],
      }),
    );

    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['ir', 'cn']);
  });

  it('leaves a pre-repair selection that is not the shipped default alone', async () => {
    // One country is a deliberate choice, and a disabled config bypasses nothing to begin with —
    // neither is the leaking default, so neither gets re-derived.
    for (const saved of [
      { enabled: true, bypassLan: true, bypassCountries: ['cn'], excludedApps: [] },
      { enabled: false, bypassLan: true, bypassCountries: ['ir', 'cn'], excludedApps: [] },
    ]) {
      resetStoreForTests();
      await AsyncStorage.setItem(SPLIT_TUNNEL_STORAGE_KEY, JSON.stringify(saved));

      await hydrateSplitTunnel();
      expect(getSnapshot().splitTunnel).toEqual(saved);
    }
  });

  it('filters unrecognized countries out of a hydrated selection', async () => {
    await AsyncStorage.setItem(
      SPLIT_TUNNEL_STORAGE_KEY,
      JSON.stringify({
        enabled: true,
        bypassLan: true,
        bypassCountries: ['us', 'ir', 7],
        excludedApps: [],
      }),
    );
    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['ir']);
  });

  it('ignores garbage persisted values (fail-open: defaults stay in place)', async () => {
    await AsyncStorage.setItem(SPLIT_TUNNEL_STORAGE_KEY, 'not json');
    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel).toEqual(DEFAULT_SPLIT_TUNNEL);

    await AsyncStorage.setItem(
      SPLIT_TUNNEL_STORAGE_KEY,
      JSON.stringify({ enabled: 'yes', bypassLan: true }),
    );
    await hydrateSplitTunnel();
    expect(getSnapshot().splitTunnel).toEqual(DEFAULT_SPLIT_TUNNEL);
  });
});

describe('connectedAtMs (session uptime stamp)', () => {
  const nativeState = (partial: Partial<NativeVpnState>): NativeVpnState => ({
    status: 'disconnected',
    relayLabel: null,
    relayName: null,
    relayClass: null,
    lastError: null,
    logLines: [],
    recents: [],
    ...partial,
  });

  let nowSpy: jest.SpyInstance<number, []>;

  beforeEach(() => {
    nowSpy = jest.spyOn(Date, 'now').mockReturnValue(1_000);
  });

  afterEach(() => {
    nowSpy.mockRestore();
  });

  it('stamps entry into connected and preserves it across connected-state events', () => {
    applyNativeState(nativeState({ status: 'connecting' }));
    expect(getSnapshot().connectedAtMs).toBeNull();

    applyNativeState(nativeState({ status: 'connected', relayLabel: 'Tokyo, Japan' }));
    expect(getSnapshot().connectedAtMs).toBe(1_000);

    // Later connected events (log lines, recents) must not restart the clock.
    nowSpy.mockReturnValue(5_000);
    applyNativeState(
      nativeState({ status: 'connected', relayLabel: 'Tokyo, Japan', logLines: ['[00:00:01] up'] }),
    );
    expect(getSnapshot().connectedAtMs).toBe(1_000);
  });

  it('clears on disconnect and re-stamps a later session (relay switch restarts the clock)', () => {
    applyNativeState(nativeState({ status: 'connected' }));
    expect(getSnapshot().connectedAtMs).toBe(1_000);

    applyNativeState(nativeState({ status: 'disconnecting' }));
    expect(getSnapshot().connectedAtMs).toBeNull();

    // Switch flow: connecting -> connected again gets a fresh stamp.
    nowSpy.mockReturnValue(9_000);
    applyNativeState(nativeState({ status: 'connecting' }));
    applyNativeState(nativeState({ status: 'connected' }));
    expect(getSnapshot().connectedAtMs).toBe(9_000);
  });

  it('stays null through failed states', () => {
    applyNativeState(nativeState({ status: 'failed', lastError: 'broker unreachable' }));
    expect(getSnapshot().connectedAtMs).toBeNull();
  });
});

describe('applyNativeState relayClass mirroring', () => {
  const nativeState = (partial: Partial<NativeVpnState>): NativeVpnState => ({
    status: 'disconnected',
    relayLabel: null,
    relayName: null,
    relayClass: null,
    lastError: null,
    logLines: [],
    recents: [],
    ...partial,
  });

  it('mirrors the connected relay class into the store', () => {
    applyNativeState(nativeState({ status: 'connected', relayClass: 'foundation' }));
    expect(getSnapshot().native.relayClass).toBe('foundation');
    applyNativeState(nativeState({ status: 'connected', relayClass: 'volunteer' }));
    expect(getSnapshot().native.relayClass).toBe('volunteer');
  });

  it('publishes a class-only change (a same-name relay of the other class is not deduped)', () => {
    applyNativeState(
      nativeState({ status: 'connected', relayName: 'proud-falcon', relayClass: 'volunteer' }),
    );
    const before = getSnapshot().native;
    applyNativeState(
      nativeState({ status: 'connected', relayName: 'proud-falcon', relayClass: 'foundation' }),
    );
    const after = getSnapshot().native;
    expect(after).not.toBe(before);
    expect(after.relayClass).toBe('foundation');
  });

  it('collapses out-of-contract values to null (stale native build omits the field)', () => {
    // A binary built before relayClass existed sends events without the key.
    const legacyEvent = nativeState({ status: 'connected' }) as unknown as Record<string, unknown>;
    delete legacyEvent.relayClass;
    applyNativeState(legacyEvent as unknown as NativeVpnState);
    expect(getSnapshot().native.relayClass).toBeNull();

    applyNativeState(
      nativeState({ status: 'connected', relayClass: 'sponsored' as unknown as 'volunteer' }),
    );
    expect(getSnapshot().native.relayClass).toBeNull();
  });
});
