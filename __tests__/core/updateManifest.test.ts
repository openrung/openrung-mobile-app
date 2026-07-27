/**
 * Update-manifest decode/verify (docs/UPDATE_MANIFEST.md): the committed vector plus negative
 * variants, the lenient-payload rules, strict version comparison, the pinned-key CI guard, and
 * the sequential fail-open fetch. Envelopes are signed with the PUBLIC test seed — the
 * production seed stays offline.
 */
const mockNativeFetchManifestCandidate = jest.fn();

jest.mock('../../src/native/OpenRungBroker', () => ({
  fetchManifestCandidate: (...args: unknown[]) =>
    mockNativeFetchManifestCandidate(...args),
}));

import * as ed from '@noble/ed25519';

import { APP_VERSION, AppConfig } from '../../src/config';
import {
  MANIFEST_CANDIDATE_URLS,
  compareVersions,
  decodeUpdateEnvelope,
  fetchUpdateManifest,
  setManifestSigningKeysForTests,
} from '../../src/net/updateManifestClient';
import { base64ToBytes, bytesToBase64, deriveKeyId, utf8Bytes } from '../helpers/bytes';
import {
  TEST_MANIFEST_KEY,
  UNPINNED_SEED_B64,
  envelopeFor,
  manifestPayload,
  manifestResponse,
  manifestVectors,
} from '../helpers/updateManifest';

const VECTOR = manifestVectors.vector;
const DIRECT_MANIFEST_URL = 'https://broker.openrung.org/api/v1/app-manifest';
const CLOUDFRONT_MANIFEST_URL =
  'https://d2r7mdpyevvs1m.cloudfront.net/api/v1/app-manifest';
const GITHUB_MANIFEST_URL =
  'https://github.com/openrung/openrung-mobile-app/releases/latest/download/update-manifest.json';

beforeEach(() => {
  setManifestSigningKeysForTests([TEST_MANIFEST_KEY]);
  mockNativeFetchManifestCandidate.mockReset();
});

afterEach(() => {
  setManifestSigningKeysForTests(null);
});

describe('decodeUpdateEnvelope — committed vector', () => {
  it('accepts the vector envelope verbatim', () => {
    const decoded = decodeUpdateEnvelope(VECTOR.envelope_json);
    expect(decoded.verified).toBe(true);
    expect(decoded.keyIdUsed).toBe(manifestVectors.test_key.key_id);
    expect(decoded.manifest.android).toEqual({ latest: '9.9.9', minSupported: '0.2.0' });
    expect(decoded.manifest.ios).toEqual({ latest: '9.9.9', minSupported: '0.2.0' });
    expect(decoded.manifest.promote).toBe('notify');
    expect(decoded.manifest.generatedAtMs).toBe(Date.parse('2026-07-22T00:00:00Z'));
    expect(decoded.manifest.notice).toEqual({
      id: 'vector-notice',
      level: 'info',
      title: { en: 'Vector notice', fa: 'اعلان آزمایشی' },
      body: { en: 'Test-only manifest vector.' },
      url: null,
      expiresMs: null,
    });
  });

  it('rejects a flipped payload byte', () => {
    const envelope = JSON.parse(VECTOR.envelope_json) as { payload_b64: string };
    const bytes = base64ToBytes(envelope.payload_b64);
    // eslint-disable-next-line no-bitwise -- deliberate single-byte tamper
    bytes[3] ^= 0x01;
    const tampered = JSON.stringify({
      ...JSON.parse(VECTOR.envelope_json),
      payload_b64: bytesToBase64(bytes),
    });
    expect(() => decodeUpdateEnvelope(tampered)).toThrow(/does not verify/);
  });

  it('rejects a flipped signature byte', () => {
    const tampered = VECTOR.envelope_json.replace(/"sig":"ed25519;([^;]+);A/, '"sig":"ed25519;$1;B');
    // Guard the test itself: the replacement must have changed something.
    const changed =
      tampered !== VECTOR.envelope_json
        ? tampered
        : VECTOR.envelope_json.replace(/0EcgHAmy/, '1EcgHAmy');
    expect(changed).not.toBe(VECTOR.envelope_json);
    expect(() => decodeUpdateEnvelope(changed)).toThrow(/invalid/);
  });

  it('rejects a signature from an unpinned key', () => {
    const envelope = envelopeFor(manifestPayload(), { seedB64: UNPINNED_SEED_B64 });
    expect(() => decodeUpdateEnvelope(envelope)).toThrow(/does not verify against any pinned key/);
  });

  it('still verifies with a wrong advisory key_id in the sig field', () => {
    const envelope = envelopeFor(manifestPayload(), { keyId: 'ffffffffffffffff' });
    const decoded = decodeUpdateEnvelope(envelope);
    expect(decoded.verified).toBe(true);
    expect(decoded.keyIdUsed).toBe(TEST_MANIFEST_KEY.keyId);
  });

  it('accepts an unsigned envelope as verified=false', () => {
    const decoded = decodeUpdateEnvelope(envelopeFor(manifestPayload(), { omitSig: true }));
    expect(decoded.verified).toBe(false);
    expect(decoded.keyIdUsed).toBeNull();
    expect(decoded.manifest.android?.latest).toBe('9.9.9');
  });
});

describe('decodeUpdateEnvelope — malformed envelopes', () => {
  const payload = manifestPayload();

  it.each([
    ['not JSON', 'nonsense{{{', /not JSON/],
    ['an array', '[1,2]', /not an object/],
    ['schema 2', JSON.stringify({ schema: 2, payload_b64: 'AAAA' }), /unsupported envelope schema/],
    ['missing payload_b64', JSON.stringify({ schema: 1 }), /payload_b64 missing/],
    ['bad base64', JSON.stringify({ schema: 1, payload_b64: '!!!!' }), /not valid base64/],
  ])('rejects %s', (_name, raw, pattern) => {
    expect(() => decodeUpdateEnvelope(raw)).toThrow(pattern);
  });

  it.each([
    ['two fields', 'ed25519;abc'],
    ['four fields', 'ed25519;a;b;c'],
    ['wrong algorithm', 'rsa;abc;AAAA'],
    ['non-base64 signature', 'ed25519;abc;@@@@'],
    ['an empty string', ''],
  ])('rejects a sig field with %s', (_name, sig) => {
    expect(() => decodeUpdateEnvelope(envelopeFor(payload, { sig }))).toThrow(/invalid/);
  });

  it('rejects a present non-string sig (only a truly absent sig decodes as unsigned)', () => {
    const bytes = JSON.parse(envelopeFor(payload, { omitSig: true })) as Record<string, unknown>;
    expect(() =>
      decodeUpdateEnvelope(JSON.stringify({ ...bytes, sig: 123 })),
    ).toThrow(/malformed sig field/);
  });

  it('rejects a truncated (63-byte) signature', () => {
    const sig63 = bytesToBase64(new Uint8Array(63).fill(7));
    expect(() =>
      decodeUpdateEnvelope(envelopeFor(payload, { sig: `ed25519;abc;${sig63}` })),
    ).toThrow(/64 bytes/);
  });

  it('rejects a payload that is not JSON', () => {
    expect(() => decodeUpdateEnvelope(envelopeFor('not json at all'))).toThrow(/not JSON/);
  });

  it('rejects an unsupported payload schema', () => {
    expect(() =>
      decodeUpdateEnvelope(envelopeFor(manifestPayload({ schema: 3 }))),
    ).toThrow(/unsupported payload schema/);
  });
});

describe('decodeUpdateEnvelope — lenient payload rules', () => {
  const decode = (overrides: Record<string, unknown>) =>
    decodeUpdateEnvelope(envelopeFor(manifestPayload(overrides)));

  it('ignores unknown fields', () => {
    const decoded = decode({ some_future_field: { deeply: 'nested' } });
    expect(decoded.manifest.android?.latest).toBe('9.9.9');
  });

  it('nulls an unparseable latest but keeps the floor', () => {
    const decoded = decode({ android: { latest: 'v9.9', min_supported: '0.2.0' } });
    expect(decoded.manifest.android).toEqual({ latest: null, minSupported: '0.2.0' });
  });

  it('drops a platform section with nothing usable', () => {
    expect(decode({ android: { latest: 42 } }).manifest.android).toBeNull();
    expect(decode({ android: 'nope' }).manifest.android).toBeNull();
  });

  it('treats an unknown promote as silent', () => {
    expect(decode({ promote: 'shout' }).manifest.promote).toBe('silent');
  });

  it('drops a notice missing id/title/body', () => {
    expect(decode({ notice: { id: 'x', title: { en: 't' } } }).manifest.notice).toBeNull();
    expect(
      decode({ notice: { id: '', title: { en: 't' }, body: { en: 'b' } } }).manifest.notice,
    ).toBeNull();
    expect(
      decode({ notice: { id: 'x', title: { fa: 'no en' }, body: { en: 'b' } } }).manifest.notice,
    ).toBeNull();
  });

  it('renders an unknown notice level as info and drops non-https urls', () => {
    const decoded = decode({
      notice: {
        id: 'n1',
        level: 'catastrophic',
        title: { en: 't' },
        body: { en: 'b' },
        url: 'http://insecure.example',
        expires: '2027-01-01T00:00:00Z',
      },
    });
    expect(decoded.manifest.notice?.level).toBe('info');
    expect(decoded.manifest.notice?.url).toBeNull();
    expect(decoded.manifest.notice?.expiresMs).toBe(Date.parse('2027-01-01T00:00:00Z'));
  });

  it('treats a missing/invalid generated_at as 0', () => {
    expect(decode({ generated_at: 'whenever' }).manifest.generatedAtMs).toBe(0);
    expect(decode({ generated_at: undefined }).manifest.generatedAtMs).toBe(0);
  });
});

describe('compareVersions', () => {
  it.each([
    ['0.3.2', '0.3.2', 0],
    ['0.3.1', '0.3.2', -1],
    ['0.3.2', '0.3.1', 1],
    ['0.9.0', '0.10.0', -1],
    ['1.0.0', '0.99.99', 1],
    ['0.0.9', '0.1.0', -1],
  ])('compares %s vs %s numerically', (a, b, expected) => {
    expect(compareVersions(a, b)).toBe(expected);
  });

  it.each([['1.2'], ['v1.2.3'], ['1.2.3-beta'], [''], ['1.2.3.4']])(
    'returns null for unparseable %p',
    bad => {
      expect(compareVersions(bad, '1.0.0')).toBeNull();
      expect(compareVersions('1.0.0', bad)).toBeNull();
    },
  );

  it('parses the real APP_VERSION', () => {
    expect(compareVersions(APP_VERSION, APP_VERSION)).toBe(0);
  });
});

describe('pinned-key CI guard', () => {
  it('MANIFEST_SIGNING_KEYS mirrors the committed pinned_keys block', () => {
    expect(AppConfig.MANIFEST_SIGNING_KEYS.map(key => key.keyId)).toEqual(
      manifestVectors.pinned_keys.map(key => key.key_id),
    );
    expect(AppConfig.MANIFEST_SIGNING_KEYS.map(key => key.publicKeyHex)).toEqual(
      manifestVectors.pinned_keys.map(key => key.public_key_hex),
    );
  });

  it('every pinned key is well-formed and its vector signature verifies', () => {
    for (const key of manifestVectors.pinned_keys) {
      const publicKey = ed.etc.hexToBytes(key.public_key_hex);
      expect(publicKey.length).toBe(32);
      expect(deriveKeyId(publicKey)).toBe(key.key_id);
      expect(
        ed.verify(
          base64ToBytes(key.vector_signature_b64),
          utf8Bytes(key.vector_message),
          publicKey,
        ),
      ).toBe(true);
    }
  });

  it('the test key derives from its committed seed', () => {
    const publicKey = ed.getPublicKey(base64ToBytes(manifestVectors.test_key.seed_b64));
    expect(ed.etc.bytesToHex(publicKey)).toBe(manifestVectors.test_key.public_key_hex);
    expect(deriveKeyId(publicKey)).toBe(manifestVectors.test_key.key_id);
  });
});

describe('fetchUpdateManifest — sequential fail-open', () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  function installNativeBodies(...bodies: (string | Error)[]): void {
    let index = 0;
    mockNativeFetchManifestCandidate.mockImplementation(
      async ({ candidateUrl }: { candidateUrl: string }) => {
        const body = bodies[index++];
        if (body instanceof Error) {
          throw body;
        }
        if (body === undefined) {
          throw new Error(`unexpected native manifest candidate: ${candidateUrl}`);
        }
        return { bodyJson: body, sourceUrl: candidateUrl };
      },
    );
  }

  // AppConfig.UPDATE_MANIFEST_URLS and the routing allowlist in updateManifestClient.ts are
  // separate pins of the same FOREVER CONTRACT. Drift is silent at runtime — an unrecognized
  // candidate throws inside the fail-open walk — so assert the two lists here as well as in the
  // transport:check guard, and prove the DEFAULT argument (production's actual input) routes.
  it('keeps AppConfig.UPDATE_MANIFEST_URLS identical to the routed candidate list', () => {
    expect(AppConfig.UPDATE_MANIFEST_URLS).toEqual([...MANIFEST_CANDIDATE_URLS]);
    expect(MANIFEST_CANDIDATE_URLS).toEqual([
      DIRECT_MANIFEST_URL,
      CLOUDFRONT_MANIFEST_URL,
      GITHUB_MANIFEST_URL,
    ]);
  });

  it('routes every default AppConfig candidate — none is silently unsupported', async () => {
    const direct = envelopeFor(manifestPayload({ generated_at: '2026-07-20T00:00:00Z' }));
    const cloudFront = envelopeFor(manifestPayload({ generated_at: '2026-07-10T00:00:00Z' }));
    const gitHub = envelopeFor(manifestPayload({ generated_at: '2026-07-05T00:00:00Z' }));
    installNativeBodies(direct, cloudFront);
    const fetchMock = jest.fn().mockResolvedValue(manifestResponse(gitHub));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    // No explicit URL list: exercises fetchUpdateManifest's default parameter exactly as the
    // update-check service calls it in production. With no cached floor the walk surveys every
    // candidate, so a config entry the router does not recognize would show up as a missing call.
    const fetched = await fetchUpdateManifest();

    expect(mockNativeFetchManifestCandidate.mock.calls).toEqual([
      [{ candidateUrl: DIRECT_MANIFEST_URL }],
      [{ candidateUrl: CLOUDFRONT_MANIFEST_URL }],
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(GITHUB_MANIFEST_URL);
    expect(fetched).toMatchObject({ url: DIRECT_MANIFEST_URL, decoded: { verified: true } });
  });

  it('routes broker and CloudFront through native, then only the exact GitHub URL through fetch', async () => {
    const unsignedDirect = envelopeFor(
      manifestPayload({ generated_at: '2026-07-01T00:00:00Z' }),
      { omitSig: true },
    );
    const unsignedCloudFront = envelopeFor(
      manifestPayload({ generated_at: '2026-07-02T00:00:00Z' }),
      { omitSig: true },
    );
    const signedGitHub = envelopeFor(
      manifestPayload({ generated_at: '2026-07-03T00:00:00Z' }),
    );
    installNativeBodies(unsignedDirect, unsignedCloudFront);
    const fetchMock = jest.fn().mockResolvedValue(manifestResponse(signedGitHub));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest([
      DIRECT_MANIFEST_URL,
      CLOUDFRONT_MANIFEST_URL,
      GITHUB_MANIFEST_URL,
    ]);

    expect(mockNativeFetchManifestCandidate.mock.calls).toEqual([
      [{ candidateUrl: DIRECT_MANIFEST_URL }],
      [{ candidateUrl: CLOUDFRONT_MANIFEST_URL }],
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(GITHUB_MANIFEST_URL);
    expect(fetched).toMatchObject({
      url: GITHUB_MANIFEST_URL,
      raw: signedGitHub,
      decoded: { verified: true },
    });
  });

  it('falls through a native broker failure to a clean native CloudFront candidate', async () => {
    const good = envelopeFor(manifestPayload());
    installNativeBodies(new Error('network down'), good);
    const fetchMock = jest.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(
      [DIRECT_MANIFEST_URL, CLOUDFRONT_MANIFEST_URL, GITHUB_MANIFEST_URL],
      { atLeastGeneratedAtMs: Date.parse('2026-07-22T00:00:00Z') },
    );

    expect(fetched?.url).toBe(CLOUDFRONT_MANIFEST_URL);
    expect(fetched?.raw).toBe(good);
    expect(mockNativeFetchManifestCandidate).toHaveBeenCalledTimes(2);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('a tampered direct candidate loses to a clean CloudFront candidate', async () => {
    const tampered = envelopeFor(manifestPayload(), { seedB64: UNPINNED_SEED_B64 });
    const clean = envelopeFor(manifestPayload());
    installNativeBodies(tampered, clean);

    const fetched = await fetchUpdateManifest([
      DIRECT_MANIFEST_URL,
      CLOUDFRONT_MANIFEST_URL,
    ]);
    expect(fetched?.url).toBe(CLOUDFRONT_MANIFEST_URL);
    expect(fetched?.decoded.verified).toBe(true);
  });

  it('keeps walking past an unsigned direct copy to a verified CloudFront copy', async () => {
    const unsigned = envelopeFor(manifestPayload(), { omitSig: true });
    const signed = envelopeFor(manifestPayload());
    installNativeBodies(unsigned, signed);

    const fetched = await fetchUpdateManifest([
      DIRECT_MANIFEST_URL,
      CLOUDFRONT_MANIFEST_URL,
    ]);
    expect(fetched?.url).toBe(CLOUDFRONT_MANIFEST_URL);
    expect(fetched?.decoded.verified).toBe(true);
    expect(mockNativeFetchManifestCandidate).toHaveBeenCalledTimes(2);
  });

  it('returns the first unsigned copy only when no candidate verifies', async () => {
    const unsignedDirect = envelopeFor(manifestPayload({ promote: 'notify' }), {
      omitSig: true,
    });
    const unsignedCloudFront = envelopeFor(manifestPayload(), { omitSig: true });
    installNativeBodies(unsignedDirect, unsignedCloudFront);

    const fetched = await fetchUpdateManifest([
      DIRECT_MANIFEST_URL,
      CLOUDFRONT_MANIFEST_URL,
    ]);
    expect(fetched?.url).toBe(DIRECT_MANIFEST_URL);
    expect(fetched?.decoded.verified).toBe(false);
  });

  it('walks past a stale signed direct front to fresh CloudFront when a floor is set', async () => {
    const stale = envelopeFor(manifestPayload({ generated_at: '2026-07-01T00:00:00Z' }));
    const fresh = envelopeFor(manifestPayload({ generated_at: '2026-07-22T00:00:00Z' }));
    installNativeBodies(stale, fresh);

    const fetched = await fetchUpdateManifest(
      [DIRECT_MANIFEST_URL, CLOUDFRONT_MANIFEST_URL],
      { atLeastGeneratedAtMs: Date.parse('2026-07-22T00:00:00Z') },
    );
    expect(fetched?.url).toBe(CLOUDFRONT_MANIFEST_URL);
    expect(mockNativeFetchManifestCandidate).toHaveBeenCalledTimes(2);
  });

  it('stops at the direct front when it is at least as fresh as the floor', async () => {
    const current = envelopeFor(manifestPayload({ generated_at: '2026-07-22T00:00:00Z' }));
    installNativeBodies(current);
    const fetchMock = jest.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(
      [DIRECT_MANIFEST_URL, CLOUDFRONT_MANIFEST_URL, GITHUB_MANIFEST_URL],
      { atLeastGeneratedAtMs: Date.parse('2026-07-22T00:00:00Z') },
    );
    expect(fetched?.url).toBe(DIRECT_MANIFEST_URL);
    expect(mockNativeFetchManifestCandidate).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('with no floor surveys native fronts and takes the newest verified envelope', async () => {
    const older = envelopeFor(manifestPayload({ generated_at: '2026-07-01T00:00:00Z' }));
    const newer = envelopeFor(manifestPayload({ generated_at: '2026-07-10T00:00:00Z' }));
    installNativeBodies(older, newer);

    const fetched = await fetchUpdateManifest([
      DIRECT_MANIFEST_URL,
      CLOUDFRONT_MANIFEST_URL,
    ]);
    expect(fetched?.url).toBe(CLOUDFRONT_MANIFEST_URL);
    expect(fetched?.decoded.manifest.generatedAtMs).toBe(
      Date.parse('2026-07-10T00:00:00Z'),
    );
  });

  it('returns null and never throws when every allowed candidate fails', async () => {
    installNativeBodies(new Error('offline'), new Error('offline'));
    const fetchMock = jest.fn().mockRejectedValue(new Error('offline'));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await expect(
      fetchUpdateManifest([
        DIRECT_MANIFEST_URL,
        CLOUDFRONT_MANIFEST_URL,
        GITHUB_MANIFEST_URL,
      ]),
    ).resolves.toBeNull();
    expect(mockNativeFetchManifestCandidate).toHaveBeenCalledTimes(2);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('rejects arbitrary candidates internally without native or JavaScript HTTP', async () => {
    const fetchMock = jest.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await expect(fetchUpdateManifest(['https://not-allowed.example/manifest'])).resolves.toBeNull();
    expect(mockNativeFetchManifestCandidate).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('uses JS fetch only for GitHub with version and cache-busting headers', async () => {
    const body = envelopeFor(manifestPayload());
    const fetchMock = jest.fn().mockResolvedValue(manifestResponse(body));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest([GITHUB_MANIFEST_URL]);
    expect(fetched?.raw).toBe(body);
    expect(mockNativeFetchManifestCandidate).not.toHaveBeenCalled();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(GITHUB_MANIFEST_URL);
    expect(init.headers).toMatchObject({
      'X-OpenRung-App-Version': APP_VERSION,
      'Cache-Control': 'no-cache, no-store',
      Pragma: 'no-cache',
    });
  });
});
