import { candidates, decodeRelayListResponse, relayListUrl } from '../../src/net/brokerClient';

describe('relayListUrl', () => {
  it('builds the relay list URL from a bare base', () => {
    expect(relayListUrl('https://broker.openrung.org/', 5)).toBe(
      'https://broker.openrung.org/api/v1/relays?limit=5',
    );
  });

  it('keeps an explicit port and cleartext scheme', () => {
    expect(relayListUrl('http://54.238.185.205:8080/', 20)).toBe(
      'http://54.238.185.205:8080/api/v1/relays?limit=20',
    );
  });

  it('preserves an existing base path', () => {
    expect(relayListUrl('https://example.com/base/', 5)).toBe(
      'https://example.com/base/api/v1/relays?limit=5',
    );
    expect(relayListUrl('https://example.com/base/deep', 7)).toBe(
      'https://example.com/base/deep/api/v1/relays?limit=7',
    );
  });

  it('replaces an existing limit param and keeps other params', () => {
    expect(relayListUrl('https://example.com/?limit=99&foo=bar', 5)).toBe(
      'https://example.com/api/v1/relays?foo=bar&limit=5',
    );
  });

  it('coerces limit < 1 to 5', () => {
    expect(relayListUrl('https://example.com/', 0)).toBe(
      'https://example.com/api/v1/relays?limit=5',
    );
    expect(relayListUrl('https://example.com/', -3)).toBe(
      'https://example.com/api/v1/relays?limit=5',
    );
  });

  it('rejects blank or scheme-less URLs', () => {
    expect(() => relayListUrl('   ', 5)).toThrow('broker URL is required');
    expect(() => relayListUrl('broker.openrung.org', 5)).toThrow(
      'broker URL must include scheme and host',
    );
  });
});

describe('decodeRelayListResponse', () => {
  const BASE_RELAY = {
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
  };
  const GEO_FIELDS = {
    city: 'Tokyo',
    country: 'Japan',
    country_code: 'JP',
    latitude: 35.6895,
    longitude: 139.6917,
  };

  function body(relays: unknown[]): string {
    return JSON.stringify({ count: relays.length, server_time: '2026-01-01T00:00:00Z', relays });
  }

  it('parses a relay carrying the broker-served location fields', () => {
    const relay = decodeRelayListResponse(body([{ ...BASE_RELAY, ...GEO_FIELDS }])).relays[0];
    expect(relay.city).toBe('Tokyo');
    expect(relay.country).toBe('Japan');
    expect(relay.country_code).toBe('JP');
    expect(relay.latitude).toBe(35.6895);
    expect(relay.longitude).toBe(139.6917);
    expect(relay.public_host).toBe('203.0.113.10'); // existing fields unchanged
  });

  it('leaves the location fields absent for a relay without them (older broker / unresolved)', () => {
    const relay = decodeRelayListResponse(body([BASE_RELAY])).relays[0];
    expect(relay.city).toBeUndefined();
    expect(relay.country).toBeUndefined();
    expect(relay.country_code).toBeUndefined();
    expect(relay.latitude).toBeUndefined();
    expect(relay.longitude).toBeUndefined();
    // The required fields still normalise exactly as before.
    expect(relay.id).toBe('relay-1');
    expect(relay.public_port).toBe(443);
  });

  it('decodes a mixed list (some relays located, some not) without errors', () => {
    const response = decodeRelayListResponse(
      body([{ ...BASE_RELAY, ...GEO_FIELDS }, { ...BASE_RELAY, id: 'relay-2' }]),
    );
    expect(response.relays).toHaveLength(2);
    expect(response.relays[0].country_code).toBe('JP');
    expect(response.relays[1].country_code).toBeUndefined();
  });

  it('drops malformed location values instead of crashing', () => {
    const relay = decodeRelayListResponse(
      body([{ ...BASE_RELAY, city: 123, country: null, latitude: '35.6', longitude: NaN }]),
    ).relays[0];
    expect(relay.city).toBeUndefined();
    expect(relay.country).toBeUndefined();
    expect(relay.latitude).toBeUndefined();
    expect(relay.longitude).toBeUndefined();
  });
});

describe('candidates', () => {
  const fallbacks = ['https://broker.openrung.org/', 'http://54.238.185.205:8080/'];

  it('puts a genuine primary override first, then the fallbacks', () => {
    expect(candidates('https://my-broker.example/', fallbacks)).toEqual([
      'https://my-broker.example/',
      'https://broker.openrung.org/',
      'http://54.238.185.205:8080/',
    ]);
  });

  it('does NOT let a primary that echoes a fallback reorder the HTTPS-first defaults', () => {
    expect(candidates('http://54.238.185.205:8080/', fallbacks)).toEqual(fallbacks);
    expect(candidates('https://broker.openrung.org/', fallbacks)).toEqual(fallbacks);
  });

  it('trims the primary before comparing against fallbacks', () => {
    expect(candidates('  https://broker.openrung.org/  ', fallbacks)).toEqual(fallbacks);
  });

  it('drops blank entries and de-duplicates while preserving order', () => {
    expect(candidates(null, ['  ', 'https://a/', 'https://a/', 'https://b/'])).toEqual([
      'https://a/',
      'https://b/',
    ]);
    expect(candidates('', fallbacks)).toEqual(fallbacks);
  });
});
