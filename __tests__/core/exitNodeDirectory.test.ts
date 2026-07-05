import { loadExitNodeDirectory } from '../../src/net/exitNodeDirectory';
import type { RelayDescriptor, RelayListResponse } from '../../src/model/relay';

const SERVER_TIME = '2026-01-01T00:00:00Z';

function relay(overrides: Partial<RelayDescriptor> = {}): RelayDescriptor {
  return {
    id: 'relay-1',
    public_host: '203.0.113.10',
    public_port: 443,
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
    ...overrides,
  };
}

const TOKYO = {
  city: 'Tokyo',
  country: 'Japan',
  country_code: 'JP',
  latitude: 35.6895,
  longitude: 139.6917,
};
const OSAKA = {
  city: 'Osaka',
  country: 'Japan',
  country_code: 'JP',
  latitude: 34.6937,
  longitude: 135.5023,
};
const BERLIN = {
  city: 'Berlin',
  country: 'Germany',
  country_code: 'DE',
  latitude: 52.5244,
  longitude: 13.4105,
};

function load(relays: RelayDescriptor[]) {
  const response: RelayListResponse = { count: relays.length, server_time: SERVER_TIME, relays };
  return loadExitNodeDirectory({ fetchRelays: async () => response });
}

describe('loadExitNodeDirectory', () => {
  it('groups located relays into one marker per country + city at the broker coordinates', async () => {
    const regions = await load([
      relay({ id: 'a', label: 'silly-lemur', ...TOKYO }),
      relay({ id: 'b', label: 'swift-harbor', ...TOKYO }),
      relay({ id: 'c', ...OSAKA }),
      relay({ id: 'd', ...BERLIN }),
    ]);
    expect(regions).toEqual([
      {
        countryCode: 'JP',
        countryName: 'Japan',
        city: 'Tokyo',
        latitude: 35.6895,
        longitude: 139.6917,
        nodeCount: 2,
        // Broker order, with the volunteer-chosen labels the list picker shows.
        relays: [
          { id: 'a', label: 'silly-lemur' },
          { id: 'b', label: 'swift-harbor' },
        ],
      },
      {
        countryCode: 'DE',
        countryName: 'Germany',
        city: 'Berlin',
        latitude: 52.5244,
        longitude: 13.4105,
        nodeCount: 1,
        relays: [{ id: 'd', label: null }],
      },
      {
        countryCode: 'JP',
        countryName: 'Japan',
        city: 'Osaka',
        latitude: 34.6937,
        longitude: 135.5023,
        nodeCount: 1,
        relays: [{ id: 'c', label: null }],
      },
    ]);
  });

  it('returns no regions when the broker sends no locations (older broker / unresolved lookups)', async () => {
    const regions = await load([relay({ id: 'a' }), relay({ id: 'b' })]);
    expect(regions).toEqual([]);
  });

  it('keeps located relays and leaves unlocated relays off the map in a mixed list', async () => {
    const regions = await load([relay({ id: 'a', ...TOKYO }), relay({ id: 'b' })]);
    expect(regions).toHaveLength(1);
    expect(regions[0].city).toBe('Tokyo');
    expect(regions[0].nodeCount).toBe(1);
  });

  it('excludes unusable relays even when the broker located them', async () => {
    const regions = await load([
      relay({ id: 'expired', expires_at: '2025-01-01T00:00:00Z', ...TOKYO }),
    ]);
    expect(regions).toEqual([]);
  });

  it('falls back to the curated country name, then the code, when the broker omits the name', async () => {
    const regions = await load([
      relay({ id: 'a', country_code: 'JP', latitude: 35.6895, longitude: 139.6917 }),
      relay({ id: 'b', country_code: 'ZZ', latitude: 1, longitude: 2 }),
    ]);
    expect(regions).toEqual([
      {
        countryCode: 'JP',
        countryName: 'Japan', // curated table
        city: null,
        latitude: 35.6895,
        longitude: 139.6917,
        nodeCount: 1,
        relays: [{ id: 'a', label: null }],
      },
      {
        countryCode: 'ZZ',
        countryName: 'ZZ', // unknown everywhere -> the code itself
        city: null,
        latitude: 1,
        longitude: 2,
        nodeCount: 1,
        relays: [{ id: 'b', label: null }],
      },
    ]);
  });

  it('needs both coordinates and a country code to place a marker', async () => {
    const regions = await load([
      relay({ id: 'no-code', latitude: 35.6895, longitude: 139.6917 }),
      relay({ id: 'no-coords', city: 'Tokyo', country: 'Japan', country_code: 'JP' }),
    ]);
    expect(regions).toEqual([]);
  });
});
