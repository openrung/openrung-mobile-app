/**
 * Update-check orchestration (src/state/updateCheck.ts): hydrate-then-fetch, success/failure
 * throttles, the cache-replacement trust ladder, and the dismissal actions — all against an
 * in-memory AsyncStorage and a stubbed fetch (Jest's react-native preset resolves Platform.OS to
 * 'ios', so fixtures drive the ios manifest section).
 */

const mockMemoryStore = new Map<string, string>();
jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async (key: string) => mockMemoryStore.get(key) ?? null),
    setItem: jest.fn(async (key: string, value: string) => {
      mockMemoryStore.set(key, value);
    }),
    removeItem: jest.fn(async (key: string) => {
      mockMemoryStore.delete(key);
    }),
  },
}));

import { setManifestSigningKeysForTests } from '../../src/net/updateManifestClient';
import { getSnapshot, resetStoreForTests } from '../../src/state/store';
import {
  UPDATE_CHECKED_AT_STORAGE_KEY,
  UPDATE_DISMISSED_BANNER_STORAGE_KEY,
  UPDATE_DISMISSED_NOTICES_STORAGE_KEY,
  UPDATE_MANIFEST_STORAGE_KEY,
  continueDespiteBlock,
  dismissUpdateBanner,
  dismissUpdateNotice,
  refreshUpdateManifest,
  resetUpdateCheckForTests,
  startUpdateCheck,
} from '../../src/state/updateCheck';
import {
  TEST_MANIFEST_KEY,
  envelopeFor,
  manifestPayload,
  manifestResponse,
} from '../helpers/updateManifest';

const originalFetch = globalThis.fetch;

/** Lets the service's fire-and-forget async chains settle. */
async function flush(): Promise<void> {
  for (let i = 0; i < 8; i++) {
    await new Promise<void>(resolve => setTimeout(() => resolve(), 0));
  }
}

function mockFetchReturning(...bodies: (string | Error)[]): jest.Mock {
  const mock = jest.fn();
  for (const body of bodies) {
    if (body instanceof Error) {
      mock.mockRejectedValueOnce(body);
    } else {
      mock.mockResolvedValueOnce(manifestResponse(body));
    }
  }
  globalThis.fetch = mock as unknown as typeof fetch;
  return mock;
}

beforeEach(() => {
  mockMemoryStore.clear();
  resetStoreForTests();
  resetUpdateCheckForTests();
  setManifestSigningKeysForTests([TEST_MANIFEST_KEY]);
});

afterEach(() => {
  resetUpdateCheckForTests();
  setManifestSigningKeysForTests(null);
  globalThis.fetch = originalFetch;
});

// APP_VERSION is 0.x.y, so ios latest 9.9.9 is always "behind".
const iosPayload = (ios: Record<string, unknown>, extra: Record<string, unknown> = {}) =>
  manifestPayload({ ios, ...extra });

describe('refreshUpdateManifest', () => {
  it('fetches, persists, and mirrors the derived tier into the store', async () => {
    const envelope = envelopeFor(iosPayload({ latest: '9.9.9', min_supported: '0.0.0' }));
    const fetchMock = mockFetchReturning(envelope);

    await refreshUpdateManifest(true);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(getSnapshot().update.tier).toBe('available');
    expect(getSnapshot().update.latestVersion).toBe('9.9.9');
    expect(mockMemoryStore.get(UPDATE_MANIFEST_STORAGE_KEY)).toBe(envelope);
    expect(Number(mockMemoryStore.get(UPDATE_CHECKED_AT_STORAGE_KEY))).toBeGreaterThan(0);
  });

  it('throttles after a success and backs off after a failure', async () => {
    const envelope = envelopeFor(iosPayload({ latest: '9.9.9' }));
    const fetchMock = mockFetchReturning(envelope);
    await refreshUpdateManifest(true);
    await refreshUpdateManifest(); // within the 6h window — must not fetch
    expect(fetchMock).toHaveBeenCalledTimes(1);

    resetUpdateCheckForTests();
    resetStoreForTests();
    mockMemoryStore.clear();
    const failing = mockFetchReturning(
      new Error('down'),
      new Error('down'),
      new Error('down'),
    );
    await refreshUpdateManifest(true); // burns all 3 candidates
    expect(getSnapshot().update.tier).toBe('none'); // fail open
    expect(mockMemoryStore.get(UPDATE_CHECKED_AT_STORAGE_KEY)).toBeUndefined();
    await refreshUpdateManifest(); // inside the 15-min failure backoff — must not fetch
    expect(failing).toHaveBeenCalledTimes(3);
  });

  it('never lets an older verified manifest roll back a newer one', async () => {
    const newer = envelopeFor(
      iosPayload({ latest: '9.9.9' }, { generated_at: '2026-07-22T00:00:00Z' }),
    );
    const older = envelopeFor(
      iosPayload({ latest: '8.8.8' }, { generated_at: '2026-07-01T00:00:00Z' }),
    );
    mockFetchReturning(newer);
    await refreshUpdateManifest(true);
    mockFetchReturning(older);
    await refreshUpdateManifest(true);

    expect(getSnapshot().update.latestVersion).toBe('9.9.9');
    expect(mockMemoryStore.get(UPDATE_MANIFEST_STORAGE_KEY)).toBe(newer);
  });

  it('never lets an unsigned manifest displace a verified one', async () => {
    const signed = envelopeFor(iosPayload({ latest: '9.9.9' }));
    const stripped = envelopeFor(
      iosPayload({ latest: '8.8.8' }, { generated_at: '2027-01-01T00:00:00Z' }),
      { omitSig: true },
    );
    mockFetchReturning(signed);
    await refreshUpdateManifest(true);
    mockFetchReturning(stripped);
    await refreshUpdateManifest(true);

    expect(getSnapshot().update.latestVersion).toBe('9.9.9');
    expect(getSnapshot().update.verified).toBe(true);
  });

  it('does not count a sig-stripped fetch against a verified cache as a success', async () => {
    mockFetchReturning(envelopeFor(iosPayload({ latest: '9.9.9' })));
    await refreshUpdateManifest(true);
    const checkedAtAfterSuccess = mockMemoryStore.get(UPDATE_CHECKED_AT_STORAGE_KEY);

    // All three candidates serve only an unsigned copy — the walk returns the unsigned fallback,
    // which must be treated as a FAILED check: no checkedAt bump, cache untouched.
    const stripped = envelopeFor(iosPayload({ latest: '8.8.8' }), { omitSig: true });
    mockFetchReturning(stripped, stripped, stripped);
    await refreshUpdateManifest(true);

    expect(mockMemoryStore.get(UPDATE_CHECKED_AT_STORAGE_KEY)).toBe(checkedAtAfterSuccess);
    expect(getSnapshot().update.latestVersion).toBe('9.9.9');
    expect(getSnapshot().update.verified).toBe(true);
  });

  it('a future persisted checkedAt (clock skew) does not freeze the check cadence', async () => {
    const T0 = 1_800_000_000_000;
    const nowSpy = jest.spyOn(Date, 'now').mockReturnValue(T0);
    try {
      // Persisted under a clock a year ahead; without the hydrate clamp this would throttle
      // every refresh until wall-clock catches up.
      mockMemoryStore.set(UPDATE_CHECKED_AT_STORAGE_KEY, String(T0 + 365 * 24 * 3_600_000));
      const fetchMock = mockFetchReturning(envelopeFor(iosPayload({ latest: '9.9.9' })));

      const stop = startUpdateCheck();
      await flush();
      // Clamped to "now": treated as freshly checked, so the cold-start refresh is throttled…
      expect(fetchMock).toHaveBeenCalledTimes(0);

      // …but one ordinary interval later the cadence resumes instead of being frozen for a year.
      nowSpy.mockReturnValue(T0 + 7 * 3_600_000);
      await refreshUpdateManifest();
      stop();
      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(getSnapshot().update.latestVersion).toBe('9.9.9');
    } finally {
      nowSpy.mockRestore();
    }
  });

  it('unsigned-over-unsigned is last-write-wins', async () => {
    mockFetchReturning(envelopeFor(iosPayload({ latest: '9.9.9' }), { omitSig: true }));
    await refreshUpdateManifest(true);
    mockFetchReturning(envelopeFor(iosPayload({ latest: '8.8.8' }), { omitSig: true }));
    await refreshUpdateManifest(true);

    expect(getSnapshot().update.latestVersion).toBe('8.8.8');
    expect(getSnapshot().update.verified).toBe(false);
  });
});

describe('startUpdateCheck', () => {
  it('hydrates a persisted manifest without fetching when the check is fresh', async () => {
    const envelope = envelopeFor(iosPayload({ latest: '9.9.9' }));
    mockMemoryStore.set(UPDATE_MANIFEST_STORAGE_KEY, envelope);
    mockMemoryStore.set(UPDATE_CHECKED_AT_STORAGE_KEY, String(Date.now()));
    const fetchMock = mockFetchReturning();

    const stop = startUpdateCheck();
    await flush();
    stop();

    expect(getSnapshot().update.tier).toBe('available');
    expect(getSnapshot().update.verified).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('drops a cached envelope that no longer verifies and keeps running', async () => {
    mockMemoryStore.set(UPDATE_MANIFEST_STORAGE_KEY, 'corrupted{{{');
    mockMemoryStore.set(UPDATE_CHECKED_AT_STORAGE_KEY, String(Date.now()));
    const fetchMock = mockFetchReturning();

    const stop = startUpdateCheck();
    await flush();
    stop();

    expect(getSnapshot().update.tier).toBe('none');
    expect(mockMemoryStore.has(UPDATE_MANIFEST_STORAGE_KEY)).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('is idempotent while started', async () => {
    mockMemoryStore.set(UPDATE_CHECKED_AT_STORAGE_KEY, String(Date.now()));
    mockFetchReturning();
    const stop = startUpdateCheck();
    const stopAgain = startUpdateCheck(); // no-op
    await flush();
    stopAgain();
    stop();
  });
});

describe('dismissals and the block override', () => {
  it('banner dismissal persists and downgrades notify -> available', async () => {
    mockFetchReturning(
      envelopeFor(iosPayload({ latest: '9.9.9' }, { promote: 'notify' })),
    );
    await refreshUpdateManifest(true);
    expect(getSnapshot().update.tier).toBe('notify');

    dismissUpdateBanner();
    expect(getSnapshot().update.tier).toBe('available');
    expect(mockMemoryStore.get(UPDATE_DISMISSED_BANNER_STORAGE_KEY)).toBe('9.9.9');
  });

  it('notice dismissal persists by id', async () => {
    const withNotice = {
      id: 'maintenance-1',
      level: 'warn',
      title: { en: 'Heads up' },
      body: { en: 'Something is changing.' },
      url: null,
      expires: null,
    };
    mockFetchReturning(envelopeFor(iosPayload({ latest: '9.9.9' }, { notice: withNotice })));
    await refreshUpdateManifest(true);
    expect(getSnapshot().update.notice?.id).toBe('maintenance-1');

    dismissUpdateNotice('maintenance-1');
    expect(getSnapshot().update.notice).toBeNull();
    expect(JSON.parse(mockMemoryStore.get(UPDATE_DISMISSED_NOTICES_STORAGE_KEY) ?? '[]')).toEqual([
      'maintenance-1',
    ]);
  });

  it('continueDespiteBlock downgrades blocked -> available for the session', async () => {
    mockFetchReturning(
      envelopeFor(iosPayload({ latest: '9.9.9', min_supported: '9.0.0' })),
    );
    await refreshUpdateManifest(true);
    expect(getSnapshot().update.tier).toBe('blocked');

    continueDespiteBlock();
    expect(getSnapshot().update.tier).toBe('available');
  });
});
