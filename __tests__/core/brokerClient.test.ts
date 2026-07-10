import { AppConfig } from '../../src/config';
import {
  candidates,
  decodeRelayListResponse,
  firstReachable,
  relayListUrl,
} from '../../src/net/brokerClient';

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

  it('puts a genuine primary override first, then the fallbacks, and flags the override', () => {
    expect(candidates('https://my-broker.example/', fallbacks)).toEqual({
      urls: [
        'https://my-broker.example/',
        'https://broker.openrung.org/',
        'http://54.238.185.205:8080/',
      ],
      overrideFirst: true,
    });
  });

  it('does NOT let a primary that echoes a fallback reorder the HTTPS-first defaults or claim the override phase', () => {
    expect(candidates('http://54.238.185.205:8080/', fallbacks)).toEqual({
      urls: fallbacks,
      overrideFirst: false,
    });
    expect(candidates('https://broker.openrung.org/', fallbacks)).toEqual({
      urls: fallbacks,
      overrideFirst: false,
    });
  });

  it('trims the primary before comparing against fallbacks', () => {
    expect(candidates('  https://broker.openrung.org/  ', fallbacks)).toEqual({
      urls: fallbacks,
      overrideFirst: false,
    });
  });

  it('drops blank entries and de-duplicates while preserving order', () => {
    expect(candidates(null, ['  ', 'https://a/', 'https://a/', 'https://b/'])).toEqual({
      urls: ['https://a/', 'https://b/'],
      overrideFirst: false,
    });
    expect(candidates('', fallbacks)).toEqual({ urls: fallbacks, overrideFirst: false });
  });
});

/** Wraps urls as a pure-race candidate list — what `candidates()` builds without an override. */
const noOverride = (...urls: string[]) => ({ urls, overrideFirst: false });
/** Wraps urls as a candidate list whose FIRST entry is a genuine user override. */
const withOverride = (...urls: string[]) => ({ urls, overrideFirst: true });

describe('firstReachable (staggered discovery race)', () => {
  const STAGGER_MS = AppConfig.DISCOVERY_STAGGER_MS;
  const PRIMARY = 'https://primary.example/';
  const SECONDARY = 'https://secondary.example/';
  const TERTIARY = 'https://tertiary.example/';

  const EMPTY_LIST = JSON.stringify({ count: 0, server_time: '2026-01-01T00:00:00Z', relays: [] });

  /** The init the client passes to fetch — always carries the merged per-attempt AbortSignal. */
  interface FetchInit {
    signal: AbortSignal;
  }
  type FetchStub = jest.Mock<Promise<unknown>, [string, FetchInit]>;

  function okResponse(): { status: number; text: () => Promise<string> } {
    return { status: 200, text: async () => EMPTY_LIST };
  }

  /** A fetch that never responds but honours its AbortSignal — a blackholed/censored endpoint. */
  function hangingFetch(init: FetchInit): Promise<unknown> {
    return new Promise((_resolve, reject) => {
      init.signal.addEventListener('abort', () => reject(new Error('aborted')));
    });
  }

  const originalFetch = (globalThis as Record<string, unknown>).fetch;
  let fetchStub: FetchStub;

  function installFetch(impl: (url: string, init: FetchInit) => Promise<unknown>): void {
    fetchStub = jest.fn(impl);
    (globalThis as Record<string, unknown>).fetch = fetchStub;
  }

  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
    (globalThis as Record<string, unknown>).fetch = originalFetch;
  });

  it('lets a healthy primary win without ever starting the fallback', async () => {
    installFetch(async () => okResponse());

    const result = await firstReachable(noOverride(PRIMARY, SECONDARY));

    expect(result.brokerUrl).toBe(PRIMARY);
    expect(fetchStub).toHaveBeenCalledTimes(1);

    // The win must also cancel the pending stagger timer: even long after the stagger interval
    // has passed, the fallback front is never contacted (keeps fallback load near zero).
    await jest.advanceTimersByTimeAsync(STAGGER_MS * 3);
    expect(fetchStub).toHaveBeenCalledTimes(1);
  });

  it('starts the fallback after one stagger and lets it beat a hanging primary', async () => {
    installFetch((url, init) =>
      url.startsWith(PRIMARY) ? hangingFetch(init) : Promise.resolve(okResponse()),
    );

    const race = firstReachable(noOverride(PRIMARY, SECONDARY));

    // Just before the stagger elapses, only the primary has been contacted.
    await jest.advanceTimersByTimeAsync(STAGGER_MS - 1);
    expect(fetchStub).toHaveBeenCalledTimes(1);

    // At the stagger boundary the fallback starts, succeeds, and wins the race even though the
    // higher-priority primary attempt is still pending (priority = head start, nothing else).
    await jest.advanceTimersByTimeAsync(1);
    await expect(race).resolves.toMatchObject({ brokerUrl: SECONDARY });
    expect(fetchStub).toHaveBeenCalledTimes(2);

    // The losing primary attempt was aborted for real: the abort reached its fetch's signal.
    const [, primaryInit] = fetchStub.mock.calls[0];
    expect(primaryInit.signal.aborted).toBe(true);
  });

  it('starts one candidate per stagger interval and aborts every loser when one wins', async () => {
    installFetch((url, init) =>
      url.startsWith(TERTIARY) ? Promise.resolve(okResponse()) : hangingFetch(init),
    );

    const race = firstReachable(noOverride(PRIMARY, SECONDARY, TERTIARY));
    expect(fetchStub).toHaveBeenCalledTimes(1); // t=0: primary starts immediately

    await jest.advanceTimersByTimeAsync(STAGGER_MS);
    expect(fetchStub).toHaveBeenCalledTimes(2); // t=1*stagger: secondary joins

    await jest.advanceTimersByTimeAsync(STAGGER_MS);
    expect(fetchStub).toHaveBeenCalledTimes(3); // t=2*stagger: tertiary joins and wins

    await expect(race).resolves.toMatchObject({ brokerUrl: TERTIARY });
    const inits = fetchStub.mock.calls.map(([, init]) => init);
    expect(inits[0].signal.aborted).toBe(true);
    expect(inits[1].signal.aborted).toBe(true);
    expect(inits[2].signal.aborted).toBe(false); // the winner itself is never aborted
  });

  it('surfaces the FIRST candidate (primary) error when every candidate fails', async () => {
    const primaryError = new Error('primary: connection reset');
    const fallbackError = new Error('fallback: HTTP 502');
    installFetch(url => Promise.reject(url.startsWith(PRIMARY) ? primaryError : fallbackError));

    // Attach handlers up front so the eventual rejection is captured, then drive the clock.
    const outcome = firstReachable(noOverride(PRIMARY, SECONDARY)).then(
      () => {
        throw new Error('expected the race to fail');
      },
      (error: unknown) => error,
    );

    // The primary fails almost instantly, but an early failure must NOT start the fallback
    // ahead of schedule — starts are driven purely by the stagger cadence.
    await jest.advanceTimersByTimeAsync(STAGGER_MS - 1);
    expect(fetchStub).toHaveBeenCalledTimes(1);

    await jest.advanceTimersByTimeAsync(1);
    expect(fetchStub).toHaveBeenCalledTimes(2);

    // The primary's error is the meaningful diagnostic — not the last-observed (fallback) one.
    expect(await outcome).toBe(primaryError);
  });

  it('with a single candidate behaves exactly like one plain attempt', async () => {
    const failure = new Error('broker down');
    installFetch(() => Promise.reject(failure));

    // The error propagates unchanged (same instance, not wrapped or replaced).
    await expect(firstReachable(noOverride(PRIMARY))).rejects.toBe(failure);
    expect(fetchStub).toHaveBeenCalledTimes(1);
    // No stagger timer was ever scheduled, and the attempt's timeout timer was cleaned up.
    expect(jest.getTimerCount()).toBe(0);
  });

  it('rejects when no candidates are configured', async () => {
    installFetch(async () => okResponse());
    await expect(firstReachable(noOverride())).rejects.toThrow('no broker endpoints configured');
    expect(fetchStub).not.toHaveBeenCalled();
  });

  describe('user-override strict phase (spec point 6)', () => {
    it('lets a genuine override slower than the stagger win — defaults are never contacted', async () => {
      // The override answers only after 3 stagger intervals: under pure race semantics the
      // default front would long since have won; under override-first it must never even start.
      installFetch(url =>
        url.startsWith(PRIMARY)
          ? new Promise(resolve => setTimeout(() => resolve(okResponse()), STAGGER_MS * 3))
          : Promise.resolve(okResponse()),
      );

      const outcome = firstReachable(withOverride(PRIMARY, SECONDARY));

      // Well past several stagger intervals, no default has been contacted.
      await jest.advanceTimersByTimeAsync(STAGGER_MS * 2);
      expect(fetchStub).toHaveBeenCalledTimes(1);

      await jest.advanceTimersByTimeAsync(STAGGER_MS);
      await expect(outcome).resolves.toMatchObject({ brokerUrl: PRIMARY });
      expect(fetchStub).toHaveBeenCalledTimes(1);
    });

    it('starts the remaining defaults only when the override FAILS, then races them on the stagger cadence', async () => {
      const overrideError = new Error('override down');
      installFetch((url, init) => {
        if (url.startsWith(PRIMARY)) {
          return new Promise((_resolve, reject) => setTimeout(() => reject(overrideError), 1_000));
        }
        return url.startsWith(SECONDARY) ? hangingFetch(init) : Promise.resolve(okResponse());
      });

      const outcome = firstReachable(withOverride(PRIMARY, SECONDARY, TERTIARY));

      // While the override is pending, no default is contacted — there is no race yet.
      await jest.advanceTimersByTimeAsync(999);
      expect(fetchStub).toHaveBeenCalledTimes(1);

      // The override's failure starts the remainder race: its first candidate immediately...
      await jest.advanceTimersByTimeAsync(1);
      expect(fetchStub).toHaveBeenCalledTimes(2);

      // ...and the next one a full stagger later, on the usual cadence.
      await jest.advanceTimersByTimeAsync(STAGGER_MS - 1);
      expect(fetchStub).toHaveBeenCalledTimes(2);
      await jest.advanceTimersByTimeAsync(1);
      await expect(outcome).resolves.toMatchObject({ brokerUrl: TERTIARY });
      expect(fetchStub).toHaveBeenCalledTimes(3);

      // The hanging default that lost the remainder race was aborted for real.
      const inits = fetchStub.mock.calls.map(([, init]) => init);
      expect(inits[1].signal.aborted).toBe(true);
      expect(inits[2].signal.aborted).toBe(false);
    });

    it('surfaces the override error when the remainder race also fails', async () => {
      const overrideError = new Error('override: connection refused');
      const defaultError = new Error('default: HTTP 502');
      installFetch(url =>
        Promise.reject(url.startsWith(PRIMARY) ? overrideError : defaultError),
      );

      const outcome = firstReachable(withOverride(PRIMARY, SECONDARY)).then(
        () => {
          throw new Error('expected the override flow to fail');
        },
        (error: unknown) => error,
      );

      // The override is candidates[0]: its error stays the surfaced diagnostic (spec point 4) —
      // the user configured that broker, so its failure is what they need to see.
      expect(await outcome).toBe(overrideError);
      expect(fetchStub).toHaveBeenCalledTimes(2);
    });

    it('with a single overridden candidate behaves exactly like one plain attempt', async () => {
      const failure = new Error('override broker down');
      installFetch(() => Promise.reject(failure));

      await expect(firstReachable(withOverride(PRIMARY))).rejects.toBe(failure);
      expect(fetchStub).toHaveBeenCalledTimes(1);
      expect(jest.getTimerCount()).toBe(0);
    });
  });
});
