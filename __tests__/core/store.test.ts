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

// Where the device is comes from host state (Intl time zone). Pin the region so the defaults are
// deterministic and tests can move the device; the region → countries mapping stays real.
jest.mock('../../src/model/splitTunnelDefaults', () => ({
  ...jest.requireActual('../../src/model/splitTunnelDefaults'),
  deviceRegion: jest.fn(() => ''),
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
import { deviceRegion } from '../../src/model/splitTunnelDefaults';
import { OpenRungVpn } from '../../src/native/OpenRungVpn';
import {
  HOME_VIEW_MODE_STORAGE_KEY,
  SPLIT_TUNNEL_APPS_STORAGE_KEY,
  SPLIT_TUNNEL_STORAGE_KEY,
  applyNativeState,
  getSnapshot,
  hydrateHomeViewMode,
  initializeSplitTunnel,
  flushSplitTunnelPush,
  refreshDirectory,
  refreshSplitTunnelRegion,
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
  const mockSetItem = AsyncStorage.setItem as jest.Mock;
  const mockRemoveItem = AsyncStorage.removeItem as jest.Mock;
  const mockRegion = deviceRegion as jest.Mock;

  /** The launch default on a device that is neither in Iran nor in China: LAN bypass only. */
  const DEFAULT_SPLIT_TUNNEL = {
    enabled: true,
    bypassLan: true,
    bypassCountries: [],
    excludedApps: [],
  };

  const pushedConfig = (
    countries: string,
    { enabled = 'true', lan = 'true', source = 'auto', packages = '[]' } = {},
  ): string =>
    `{"version":1,"enabled":${enabled},"bypass_lan":${lan},"bypass_countries":${countries},` +
    `"country_source":"${source}","excluded_packages":${packages}}`;

  /** A new launch of the app: a fresh JS process over whatever storage already holds. */
  function relaunchApp(): void {
    resetStoreForTests();
    mockSetSplitTunnelConfig.mockClear();
    mockSetItem.mockClear();
    mockRemoveItem.mockClear();
  }

  beforeEach(async () => {
    await AsyncStorage.removeItem(SPLIT_TUNNEL_STORAGE_KEY);
    await AsyncStorage.removeItem(SPLIT_TUNNEL_APPS_STORAGE_KEY);
    // Outside Iran and China unless a test places the device somewhere else; re-derive the
    // launch slice so the change takes effect.
    mockRegion.mockReturnValue('');
    relaunchApp();
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
    mockRegion.mockReturnValue('IR');
    relaunchApp();
    expect(getSnapshot().splitTunnel).toEqual({ ...DEFAULT_SPLIT_TUNNEL, bypassCountries: ['ir'] });

    mockRegion.mockReturnValue('CN');
    relaunchApp();
    expect(getSnapshot().splitTunnel).toEqual({ ...DEFAULT_SPLIT_TUNNEL, bypassCountries: ['cn'] });
  });

  it('setSplitTunnel merges and pushes the contract JSON after the debounce', () => {
    setSplitTunnel({ enabled: true, bypassCountries: ['ir'] });
    expect(getSnapshot().splitTunnel).toEqual({
      enabled: true,
      bypassLan: true,
      bypassCountries: ['ir'],
      excludedApps: [],
    });

    // The native push waits out the debounce, then sends the §3 JSON with the stable
    // key order the native stores compare against verbatim.
    expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      pushedConfig('["ir"]', { source: 'manual' }),
    );
  });

  it('collapses rapid changes into a single debounced push of the final state', () => {
    setSplitTunnel({ enabled: true, bypassCountries: ['cn'] });
    jest.advanceTimersByTime(600);
    setSplitTunnel({ bypassLan: false });
    jest.advanceTimersByTime(1199);
    expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();

    jest.advanceTimersByTime(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      pushedConfig('["cn"]', { lan: 'false', source: 'manual' }),
    );
  });

  describe('session-scoped selections', () => {
    it('never writes a routing selection to storage', async () => {
      setSplitTunnel({ enabled: false, bypassLan: false, bypassCountries: ['cn'] });
      jest.advanceTimersByTime(1200);

      // The push reached native (the service needs it for THIS session) but nothing was saved.
      expect(mockSetSplitTunnelConfig).toHaveBeenCalled();
      expect(mockSetItem).not.toHaveBeenCalledWith(SPLIT_TUNNEL_STORAGE_KEY, expect.anything());
      expect(await AsyncStorage.getItem(SPLIT_TUNNEL_STORAGE_KEY)).toBeNull();
    });

    it('starts the next launch from the routing default, discarding those edits', async () => {
      mockRegion.mockReturnValue('CN');
      relaunchApp();
      setSplitTunnel({ enabled: false, bypassLan: false, bypassCountries: ['ir'] });
      jest.advanceTimersByTime(1200);

      relaunchApp();
      expect(getSnapshot().splitTunnel).toEqual({
        ...DEFAULT_SPLIT_TUNNEL,
        bypassCountries: ['cn'],
      });

      // And native is told, so the routing returns to the default too — not just the toggles.
      await initializeSplitTunnel();
      jest.advanceTimersByTime(1200);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(pushedConfig('["cn"]'));
    });

    it('remembers the bypassed-apps list across launches', async () => {
      // Picking apps out of everything installed is real work, and "my bank refuses the VPN" is a
      // lasting statement — unlike a temporary routing tweak. So apps are exempt from the reset.
      setSplitTunnel({ excludedApps: ['com.tencent.mm', 'org.telegram.messenger'] });
      jest.advanceTimersByTime(1200);
      expect(await AsyncStorage.getItem(SPLIT_TUNNEL_APPS_STORAGE_KEY)).toBe(
        '["com.tencent.mm","org.telegram.messenger"]',
      );

      relaunchApp();
      // Before the read lands the list is empty; initialization restores it.
      await initializeSplitTunnel();
      expect(getSnapshot().splitTunnel.excludedApps).toEqual([
        'com.tencent.mm',
        'org.telegram.messenger',
      ]);

      // Native gets ONE config carrying both the launch routing default and the remembered apps.
      jest.advanceTimersByTime(1200);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
        pushedConfig('[]', { packages: '["com.tencent.mm","org.telegram.messenger"]' }),
      );
    });

    it('lets a cleared apps list survive too, and ignores a malformed one', async () => {
      setSplitTunnel({ excludedApps: ['com.tencent.mm'] });
      setSplitTunnel({ excludedApps: [] });
      relaunchApp();
      await initializeSplitTunnel();
      expect(getSnapshot().splitTunnel.excludedApps).toEqual([]);

      await AsyncStorage.setItem(SPLIT_TUNNEL_APPS_STORAGE_KEY, 'not json');
      relaunchApp();
      await initializeSplitTunnel();
      expect(getSnapshot().splitTunnel.excludedApps).toEqual([]);
    });

    it('does not let the launch read overwrite an apps edit made first', async () => {
      await AsyncStorage.setItem(SPLIT_TUNNEL_APPS_STORAGE_KEY, '["com.stale.package"]');
      relaunchApp();

      const initializing = initializeSplitTunnel();
      setSplitTunnel({ excludedApps: ['com.chosen.now'] });
      await initializing;

      expect(getSnapshot().splitTunnel.excludedApps).toEqual(['com.chosen.now']);
    });

    it('ignores the whole-slice preference persisted by an older build, and deletes it', async () => {
      await AsyncStorage.setItem(
        SPLIT_TUNNEL_STORAGE_KEY,
        JSON.stringify({
          enabled: false,
          bypassLan: false,
          bypassCountries: ['ir', 'cn'],
          excludedApps: ['com.tencent.mm'],
        }),
      );
      relaunchApp();

      await initializeSplitTunnel();
      expect(getSnapshot().splitTunnel).toEqual(DEFAULT_SPLIT_TUNNEL);
      expect(await AsyncStorage.getItem(SPLIT_TUNNEL_STORAGE_KEY)).toBeNull();
    });

    it('coalesces concurrent initialization into one cleanup and one push', async () => {
      relaunchApp();
      const first = initializeSplitTunnel();
      const second = initializeSplitTunnel();
      expect(second).toBe(first);
      await Promise.all([first, second]);

      expect(mockRemoveItem).toHaveBeenCalledTimes(1);
      jest.advanceTimersByTime(1200);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    });

    it('keeps an edit made before initialization finished', async () => {
      relaunchApp();
      const initializing = initializeSplitTunnel();
      setSplitTunnel({ bypassLan: false });
      await initializing;

      jest.advanceTimersByTime(1200);
      expect(getSnapshot().splitTunnel.bypassLan).toBe(false);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(pushedConfig('[]', { lan: 'false' }));
    });
  });

  it('pushes this launch default before the first connect can read it', async () => {
    mockRegion.mockReturnValue('CN');
    relaunchApp();

    await flushSplitTunnelPush();

    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(pushedConfig('["cn"]'));
  });

  it('tells native whether the country selection is automatic', async () => {
    // The native generators re-derive an automatic selection from the device's own time zone on
    // every config build, including the background recovery rebuilds no JS code takes part in.
    // They can only do that if this flag reaches them.
    mockRegion.mockReturnValue('CN');
    relaunchApp();

    await flushSplitTunnelPush();
    expect(mockSetSplitTunnelConfig).toHaveBeenLastCalledWith(
      expect.stringContaining('"country_source":"auto"'),
    );

    setSplitTunnel({ bypassCountries: ['ir'] });
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenLastCalledWith(
      expect.stringContaining('"country_source":"manual"'),
    );
  });

  it('stops tracking the region once the user picks countries, but not for other edits', () => {
    mockRegion.mockReturnValue('CN');
    relaunchApp();

    // A LAN edit says nothing about which country's rule set belongs here, so the selection stays
    // automatic and keeps following the device.
    setSplitTunnel({ bypassLan: false });
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenLastCalledWith(
      pushedConfig('["cn"]', { lan: 'false' }),
    );

    // Choosing a country freezes it for the rest of the session.
    setSplitTunnel({ bypassCountries: ['ir'] });
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).toHaveBeenLastCalledWith(
      pushedConfig('["ir"]', { lan: 'false', source: 'manual' }),
    );
  });

  describe('mid-session travel (the JS process outlives the flight)', () => {
    /** Auto-selects ['cn'] in China, then moves the device without restarting the process. */
    function landInBerlinAfterAutoSelectingChina(): void {
      mockRegion.mockReturnValue('CN');
      relaunchApp();
      expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['cn']);
      // The flight. Same JS process, same module state.
      mockRegion.mockReturnValue('');
    }

    it('re-derives on foreground', () => {
      landInBerlinAfterAutoSelectingChina();

      refreshSplitTunnelRegion();
      expect(getSnapshot().splitTunnel.bypassCountries).toEqual([]);

      jest.advanceTimersByTime(1200);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(pushedConfig('[]'));
    });

    it('corrects the config before a connect can read it', async () => {
      landInBerlinAfterAutoSelectingChina();

      // The connect path's own pre-flight. It must not hand the service ['cn'] in Berlin.
      await flushSplitTunnelPush();

      expect(getSnapshot().splitTunnel.bypassCountries).toEqual([]);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
      expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(pushedConfig('[]'));
    });

    it('leaves a hand-picked selection alone across the same move', async () => {
      mockRegion.mockReturnValue('CN');
      relaunchApp();
      setSplitTunnel({ bypassCountries: ['cn'] });
      mockRegion.mockReturnValue('');

      refreshSplitTunnelRegion();
      await flushSplitTunnelPush();
      expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['cn']);
    });

    it('is a no-op while the device stays put', () => {
      mockRegion.mockReturnValue('CN');
      relaunchApp();

      refreshSplitTunnelRegion();
      jest.advanceTimersByTime(1200);
      expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['cn']);
      expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();
    });
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
