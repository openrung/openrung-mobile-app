/**
 * refreshDirectory no-op semantics (production OpenRungStatusStore.refreshDirectory):
 * no-op while a load is in flight or after a successful NON-EMPTY load, unless forced.
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
      clear: jest.fn(async () => {
        storage.clear();
      }),
    },
  };
});

jest.mock('../../src/native/OpenRungVpn', () => ({
  OpenRungVpn: { measureLatency: jest.fn() },
}));

import AsyncStorage from '@react-native-async-storage/async-storage';
import { OpenRungVpn } from '../../src/native/OpenRungVpn';
import {
  FAVORITES_STORAGE_KEY,
  fastestCountry,
  getSnapshot,
  hydratePreferences,
  recordLastExit,
  refreshDirectory,
  resetStoreForTests,
  runLatencyTest,
  setAutoConnectEnabled,
  setRememberExitEnabled,
  toggleFavorite,
} from '../../src/state/store';
import type { LatencyMeasurement } from '../../src/native/types';

const measureLatencyMock = OpenRungVpn.measureLatency as jest.MockedFunction<
  typeof OpenRungVpn.measureLatency
>;

interface MockResponse {
  status: number;
  text: () => Promise<string>;
}

function jsonResponse(payload: unknown): MockResponse {
  return { status: 200, text: async () => JSON.stringify(payload) };
}

const RELAY_LIST = {
  count: 1,
  server_time: '2026-01-01T00:00:00Z',
  relays: [
    {
      id: 'tokyo-volunteer-1',
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

beforeEach(async () => {
  resetStoreForTests();
  installFetch();
  measureLatencyMock.mockReset();
  await AsyncStorage.clear();
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
        probeTargets: [{ host: '203.0.113.10', port: 443 }],
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

describe('favorites', () => {
  it('toggles a country in and out, normalizing to uppercase', () => {
    toggleFavorite('jp');
    expect(getSnapshot().favorites).toEqual(['JP']);
    toggleFavorite('DE');
    expect(getSnapshot().favorites).toEqual(['JP', 'DE']);
    toggleFavorite('JP');
    expect(getSnapshot().favorites).toEqual(['DE']);
  });

  it('ignores blank codes', () => {
    toggleFavorite('  ');
    expect(getSnapshot().favorites).toEqual([]);
  });

  it('round-trips through AsyncStorage via hydratePreferences', async () => {
    toggleFavorite('JP');
    toggleFavorite('DE');
    resetStoreForTests();
    expect(getSnapshot().favorites).toEqual([]);
    await hydratePreferences();
    expect(getSnapshot().favorites).toEqual(['JP', 'DE']);
    expect(getSnapshot().prefsHydrated).toBe(true);
  });

  it('keeps the default on a malformed persisted payload but still completes hydration', async () => {
    await AsyncStorage.setItem(FAVORITES_STORAGE_KEY, 'not json');
    await hydratePreferences();
    expect(getSnapshot().favorites).toEqual([]);
    expect(getSnapshot().prefsHydrated).toBe(true);
  });
});

describe('connection preferences', () => {
  it('persists auto-connect and remember-exit toggles across hydration', async () => {
    setAutoConnectEnabled(true);
    setRememberExitEnabled(false);
    resetStoreForTests();
    await hydratePreferences();
    expect(getSnapshot().autoConnectEnabled).toBe(true);
    expect(getSnapshot().rememberExitEnabled).toBe(false);
  });

  it('records the last requested exit only while remember-exit is on', async () => {
    recordLastExit('jp');
    expect(getSnapshot().lastExitCountry).toBe('JP'); // default: remember on

    setRememberExitEnabled(false);
    recordLastExit('DE');
    expect(getSnapshot().lastExitCountry).toBe('JP'); // unchanged while off
  });

  it("round-trips the broker-picks case (null) as ''", async () => {
    recordLastExit('JP');
    recordLastExit(null);
    expect(getSnapshot().lastExitCountry).toBeNull();
    resetStoreForTests();
    await hydratePreferences();
    expect(getSnapshot().lastExitCountry).toBeNull();
  });
});

describe('latency test + fastest', () => {
  // A relay list with two located countries (JP faster than DE) for the fastest picker.
  const TWO_COUNTRY_LIST = {
    count: 2,
    server_time: '2026-01-01T00:00:00Z',
    relays: [
      { ...RELAY_LIST.relays[0], id: 'jp', public_host: '203.0.113.10' },
      {
        ...RELAY_LIST.relays[0],
        id: 'de',
        public_host: '203.0.113.20',
        city: 'Berlin',
        country: 'Germany',
        country_code: 'DE',
        latitude: 52.52,
        longitude: 13.4,
      },
    ],
  };

  it('runs the probe, stores results, and picks the lowest-RTT country', async () => {
    installFetch(TWO_COUNTRY_LIST);
    await refreshDirectory();

    measureLatencyMock.mockImplementation(
      async (targets): Promise<LatencyMeasurement> => ({
        viaTunnel: false,
        results: targets.map(target => ({
          id: target.id,
          latencyMs: target.id.startsWith('JP') ? 60 : 200,
          reachable: true,
        })),
      }),
    );

    await runLatencyTest();
    const snap = getSnapshot();
    expect(snap.latency.status).toBe('done');
    expect(snap.latency.results['JP|Tokyo'].rttMs).toBe(60);
    expect(snap.latency.results['DE|Berlin'].rttMs).toBe(200);
    expect(fastestCountry(snap)).toEqual({ countryCode: 'JP', rttMs: 60 });
  });

  it('ignores unreachable regions when picking the fastest', async () => {
    installFetch(TWO_COUNTRY_LIST);
    await refreshDirectory();
    measureLatencyMock.mockImplementation(
      async (targets): Promise<LatencyMeasurement> => ({
        viaTunnel: false,
        results: targets.map(target => ({
          id: target.id,
          latencyMs: target.id.startsWith('JP') ? null : 200,
          reachable: !target.id.startsWith('JP'),
        })),
      }),
    );
    await runLatencyTest();
    expect(fastestCountry(getSnapshot())).toEqual({ countryCode: 'DE', rttMs: 200 });
  });

  it('marks the test failed when the native probe throws', async () => {
    installFetch(TWO_COUNTRY_LIST);
    await refreshDirectory();
    measureLatencyMock.mockRejectedValue(new Error('probe boom'));
    await runLatencyTest();
    expect(getSnapshot().latency.status).toBe('failed');
    expect(fastestCountry(getSnapshot())).toBeNull();
  });

  it('resets latency results when the directory is refreshed', async () => {
    installFetch(TWO_COUNTRY_LIST);
    await refreshDirectory();
    measureLatencyMock.mockResolvedValue({
      viaTunnel: false,
      results: [{ id: 'JP|Tokyo#0', latencyMs: 60, reachable: true }],
    });
    await runLatencyTest();
    expect(getSnapshot().latency.status).toBe('done');

    await refreshDirectory(true);
    expect(getSnapshot().latency.status).toBe('idle');
    expect(getSnapshot().latency.results).toEqual({});
  });
});
