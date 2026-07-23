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

// The store pushes split-tunnel configs through the OpenRungVpn bridge; the mock keeps the
// suite off the scripted simulator and lets the push payloads be asserted verbatim.
jest.mock('../../src/native/OpenRungVpn', () => ({
  OpenRungVpn: {
    setSplitTunnelConfig: jest.fn(async () => {}),
  },
}));

import AsyncStorage from '@react-native-async-storage/async-storage';

import { AppConfig } from '../../src/config';
import { OpenRungVpn } from '../../src/native/OpenRungVpn';
import { setRelaySigningKeysForTests } from '../../src/net/brokerClient';
import {
  HOME_VIEW_MODE_STORAGE_KEY,
  SPLIT_TUNNEL_STORAGE_KEY,
  applyNativeState,
  getSnapshot,
  hydrateHomeViewMode,
  hydrateSplitTunnel,
  refreshDirectory,
  resetStoreForTests,
  setHomeViewMode,
  setSplitTunnel,
} from '../../src/state/store';
import type { NativeVpnState } from '../../src/native/types';
import { TEST_SIGNING_KEY, signedApiBody, signedResponse } from '../helpers/signing';

/**
 * A relay-list response as the production broker serves it: Ed25519-signed (with the public
 * §2.3 test key, pinned in beforeEach) and echoing the directory request's
 * DIRECTORY_RELAY_LIMIT — the default broker candidates are non-loopback, so refreshDirectory
 * only ever accepts verified lists.
 */
function jsonResponse(payload: unknown): unknown {
  return signedResponse(
    signedApiBody({
      ...(payload as Record<string, unknown>),
      limit: AppConfig.DIRECTORY_RELAY_LIMIT,
    }),
  );
}

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

let relayFetches: number;

function installFetch(relayPayload: unknown = RELAY_LIST): void {
  relayFetches = 0;
  (globalThis as Record<string, unknown>).fetch = jest.fn(async (url: string) => {
    if (url.includes('/api/v1/relays')) {
      relayFetches++;
      return jsonResponse(relayPayload);
    }
    // Anything else — notably ipwho.is — must never be contacted for relays.
    throw new Error(`unexpected fetch: ${url}`);
  });
}

beforeEach(() => {
  resetStoreForTests();
  setRelaySigningKeysForTests([TEST_SIGNING_KEY]);
  installFetch();
});

afterEach(() => {
  setRelaySigningKeysForTests(null);
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
        relays: [{ id: 'tokyo-relay-1', label: null }],
      },
    ]);
    expect(relayFetches).toBe(1);
  });

  it('is a no-op after a successful non-empty load', async () => {
    await refreshDirectory();
    expect(relayFetches).toBe(1);
    await refreshDirectory();
    expect(relayFetches).toBe(1); // unchanged
    expect(getSnapshot().directoryStatus).toBe('loaded');
  });

  it('reloads when forced', async () => {
    await refreshDirectory();
    expect(relayFetches).toBe(1);
    await refreshDirectory(true);
    expect(relayFetches).toBe(2);
    expect(getSnapshot().directoryStatus).toBe('loaded');
  });

  it('is a no-op while a load is already in flight', async () => {
    const first = refreshDirectory();
    expect(getSnapshot().directoryStatus).toBe('loading');
    const second = refreshDirectory(); // resolves immediately without fetching
    await Promise.all([first, second]);
    expect(relayFetches).toBe(1);
  });

  it('re-fetches after a load that returned no regions (loaded-but-empty is not "already loaded")', async () => {
    installFetch({ count: 0, server_time: '2026-01-01T00:00:00Z', relays: [] });
    await refreshDirectory();
    expect(getSnapshot().directoryStatus).toBe('loaded');
    expect(getSnapshot().availableRegions).toEqual([]);
    await refreshDirectory(); // no force needed: empty load must not latch
    expect(relayFetches).toBe(2);
  });

  it('marks the directory failed when every broker candidate fails, then allows a retry', async () => {
    (globalThis as Record<string, unknown>).fetch = jest.fn(async () => {
      throw new Error('network down');
    });
    await refreshDirectory();
    expect(getSnapshot().directoryStatus).toBe('failed');

    installFetch();
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

  const DEFAULT_SPLIT_TUNNEL = {
    enabled: false,
    bypassLan: true,
    bypassCountries: [],
    excludedApps: [],
  };

  beforeEach(async () => {
    await AsyncStorage.removeItem(SPLIT_TUNNEL_STORAGE_KEY);
    mockGetItem.mockClear();
    mockSetSplitTunnelConfig.mockClear();
    jest.useFakeTimers();
  });

  afterEach(() => {
    resetStoreForTests(); // cancels any pending debounced push before real timers return
    jest.useRealTimers();
  });

  it('defaults to disabled with LAN bypass on', () => {
    expect(getSnapshot().splitTunnel).toEqual(DEFAULT_SPLIT_TUNNEL);
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
      JSON.stringify(getSnapshot().splitTunnel),
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
    setSplitTunnel({ enabled: true });
    jest.advanceTimersByTime(600);
    setSplitTunnel({ bypassLan: false });
    jest.advanceTimersByTime(1199);
    expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();

    jest.advanceTimersByTime(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledTimes(1);
    expect(mockSetSplitTunnelConfig).toHaveBeenCalledWith(
      '{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":[],"excluded_packages":[]}',
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

  it('does not push to native when nothing is persisted (no live-tunnel bounce on first open)', async () => {
    // Fresh install / first launch after the feature ships: AsyncStorage is empty, the native
    // store is likewise empty, and there is nothing to sync — so merely opening the screen must
    // not push a config (which could otherwise bounce a connected tunnel for a no-op change).
    await hydrateSplitTunnel();
    jest.advanceTimersByTime(1200);
    expect(mockSetSplitTunnelConfig).not.toHaveBeenCalled();
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
