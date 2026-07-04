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
    },
  };
});

import { getSnapshot, refreshDirectory, resetStoreForTests } from '../../src/state/store';

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

beforeEach(() => {
  resetStoreForTests();
  installFetch();
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
