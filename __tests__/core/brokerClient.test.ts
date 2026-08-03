const mockNativeFirstReachable = jest.fn();

jest.mock('../../src/native/OpenRungBroker', () => ({
  ...jest.requireActual('../../src/native/OpenRungBroker'),
  firstReachable: (...args: unknown[]) => mockNativeFirstReachable(...args),
}));

import {
  decodeRelayListResponse,
  firstReachable,
} from '../../src/net/brokerClient';
import { OpenRungBrokerError } from '../../src/native/OpenRungBroker';

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

function relayBody(relays: unknown[]): string {
  return JSON.stringify({
    count: relays.length,
    server_time: '2026-01-01T00:00:00Z',
    relays,
  });
}

beforeEach(() => {
  mockNativeFirstReachable.mockReset();
});

describe('decodeRelayListResponse', () => {
  it('decodes the established relay and broker-served geo model', () => {
    const response = decodeRelayListResponse(
      relayBody([{ ...BASE_RELAY, ...GEO_FIELDS }]),
    );

    expect(response).toMatchObject({
      count: 1,
      server_time: '2026-01-01T00:00:00Z',
    });
    expect(response.relays[0]).toMatchObject({
      id: 'relay-1',
      public_host: '203.0.113.10',
      public_port: 443,
      city: 'Tokyo',
      country: 'Japan',
      country_code: 'JP',
      latitude: 35.6895,
      longitude: 139.6917,
    });
  });

  it('decodes node_class and leaves it absent when the broker omits or mangles it', () => {
    const response = decodeRelayListResponse(
      relayBody([
        { ...BASE_RELAY, node_class: 'foundation' },
        { ...BASE_RELAY, id: 'relay-2', node_class: 'volunteer' },
        { ...BASE_RELAY, id: 'relay-3' }, // older broker: no node_class on the wire
        { ...BASE_RELAY, id: 'relay-4', node_class: 123 },
      ]),
    );

    expect(response.relays[0].node_class).toBe('foundation');
    expect(response.relays[1].node_class).toBe('volunteer');
    // Absent/malformed stays undefined here; the directory collapses it to 'volunteer'.
    expect(response.relays[2].node_class).toBeUndefined();
    expect(response.relays[3].node_class).toBeUndefined();
  });

  it('keeps optional geo fields absent and normalizes malformed values', () => {
    const response = decodeRelayListResponse(
      relayBody([
        BASE_RELAY,
        {
          ...BASE_RELAY,
          id: 'relay-2',
          city: 123,
          country: null,
          latitude: '35.6',
          longitude: Number.NaN,
          public_port: '443',
        },
      ]),
    );

    expect(response.relays[0].city).toBeUndefined();
    expect(response.relays[0].latitude).toBeUndefined();
    expect(response.relays[1]).toMatchObject({
      id: 'relay-2',
      public_port: 0,
    });
    expect(response.relays[1].city).toBeUndefined();
    expect(response.relays[1].longitude).toBeUndefined();
  });

  it.each(['not JSON', '[]', '{"count":0,"relays":[]}'])(
    'returns a structured decode failure for malformed relay JSON (%s)',
    body => {
      try {
        decodeRelayListResponse(body);
        throw new Error('expected relay decoding to fail');
      } catch (error) {
        expect(error).toMatchObject({ kind: 'decode' });
      }
    },
  );
});

describe('firstReachable native adapter', () => {
  it('forwards primary, limit, paired identity, and signal then decodes relayJson', async () => {
    const signal = new AbortController().signal;
    mockNativeFirstReachable.mockResolvedValue({
      brokerUrl: 'https://winner.example/',
      relayJson: relayBody([{ ...BASE_RELAY, ...GEO_FIELDS }]),
      keyId: 'verified-key',
      signatureVerified: true,
    });

    const result = await firstReachable(' https://custom.example/base ', {
      limit: 20,
      clientId: 'client-a',
      sessionId: 'session-a',
      signal,
    });

    expect(mockNativeFirstReachable).toHaveBeenCalledWith(
      {
        primary: ' https://custom.example/base ',
        limit: 20,
        clientId: 'client-a',
        sessionId: 'session-a',
      },
      signal,
    );
    expect(result.brokerUrl).toBe('https://winner.example/');
    expect(result.response.relays[0].country_code).toBe('JP');
  });

  it('uses the selector default limit and an empty native session token', async () => {
    mockNativeFirstReachable.mockResolvedValue({
      brokerUrl: 'https://winner.example/',
      relayJson: relayBody([]),
      keyId: '',
      signatureVerified: true,
    });

    await firstReachable('https://primary.example/', {
      clientId: 'client-a',
      sessionId: null,
    });

    expect(mockNativeFirstReachable).toHaveBeenCalledWith(
      {
        primary: 'https://primary.example/',
        limit: 5,
        clientId: 'client-a',
        sessionId: '',
      },
      undefined,
    );
  });

  it('preserves a structured native transport failure', async () => {
    const failure = new OpenRungBrokerError('dns', 'DNS lookup failed');
    mockNativeFirstReachable.mockRejectedValue(failure);

    await expect(
      firstReachable('https://primary.example/', {
        clientId: 'client-a',
      }),
    ).rejects.toBe(failure);
  });

  it('maps malformed copied relayJson to a local decode failure without retrying', async () => {
    mockNativeFirstReachable.mockResolvedValue({
      brokerUrl: 'https://winner.example/',
      relayJson: '{"count":',
      keyId: '',
      signatureVerified: true,
    });

    await expect(
      firstReachable('https://primary.example/', {
        clientId: 'client-a',
      }),
    ).rejects.toMatchObject({ kind: 'decode' });
    expect(mockNativeFirstReachable).toHaveBeenCalledTimes(1);
  });

  // Relay verification lives in Go now, but this repo must not become indifferent to whether it
  // happened: an unverified snapshot is rejected here rather than drawn as map pins. brokerapi
  // only reports false for a loopback endpoint, and the directory broker URL is never loopback.
  it('rejects an unverified relay snapshot instead of decoding it', async () => {
    mockNativeFirstReachable.mockResolvedValue({
      brokerUrl: 'https://winner.example/',
      relayJson: relayBody([{ ...BASE_RELAY, ...GEO_FIELDS }]),
      keyId: '',
      signatureVerified: false,
    });

    await expect(
      firstReachable('https://primary.example/', {
        clientId: 'client-a',
      }),
    ).rejects.toMatchObject({ kind: 'verification' });
    expect(mockNativeFirstReachable).toHaveBeenCalledTimes(1);
  });
});
