/**
 * Update-manifest decode/verify (docs/UPDATE_MANIFEST.md): the committed vector plus negative
 * variants, the lenient-payload rules, strict version comparison, the pinned-key CI guard, and
 * the sequential fail-open fetch. Envelopes are signed with the PUBLIC test seed — the
 * production seed stays offline.
 */
import * as ed from '@noble/ed25519';

import { APP_VERSION, AppConfig } from '../../src/config';
import {
  compareVersions,
  decodeUpdateEnvelope,
  fetchUpdateManifest,
  setManifestSigningKeysForTests,
} from '../../src/net/updateManifestClient';
import { base64ToBytes, bytesToBase64, deriveKeyId, utf8Bytes } from '../helpers/signing';
import {
  TEST_MANIFEST_KEY,
  UNPINNED_SEED_B64,
  envelopeFor,
  manifestPayload,
  manifestResponse,
  manifestVectors,
} from '../helpers/updateManifest';

const VECTOR = manifestVectors.vector;

beforeEach(() => {
  setManifestSigningKeysForTests([TEST_MANIFEST_KEY]);
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

  it('falls through failing candidates to the first good one', async () => {
    const good = envelopeFor(manifestPayload());
    const fetchMock = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse('irrelevant', 404))
      .mockRejectedValueOnce(new Error('network down'))
      .mockResolvedValueOnce(manifestResponse(good));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://a/', 'https://b/', 'https://c/']);
    expect(fetched?.url).toBe('https://c/');
    expect(fetched?.raw).toBe(good);
    expect(fetched?.decoded.verified).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it('a tampered candidate loses to a clean later candidate', async () => {
    const clean = envelopeFor(manifestPayload());
    const tampered = envelopeFor(manifestPayload(), { seedB64: UNPINNED_SEED_B64 });
    globalThis.fetch = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse(tampered))
      .mockResolvedValueOnce(manifestResponse(clean)) as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://bad/', 'https://good/']);
    expect(fetched?.url).toBe('https://good/');
  });

  it('keeps walking past an unsigned copy to a verified one on a later front', async () => {
    const unsigned = envelopeFor(manifestPayload(), { omitSig: true });
    const signed = envelopeFor(manifestPayload());
    const fetchMock = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse(unsigned))
      .mockResolvedValueOnce(manifestResponse(signed));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://stripped/', 'https://signed/']);
    expect(fetched?.url).toBe('https://signed/');
    expect(fetched?.decoded.verified).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('returns the first unsigned copy only when no candidate verifies', async () => {
    const unsignedA = envelopeFor(manifestPayload({ promote: 'notify' }), { omitSig: true });
    const unsignedB = envelopeFor(manifestPayload(), { omitSig: true });
    globalThis.fetch = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse(unsignedA))
      .mockResolvedValueOnce(manifestResponse(unsignedB)) as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://a/', 'https://b/']);
    expect(fetched?.url).toBe('https://a/');
    expect(fetched?.decoded.verified).toBe(false);
  });

  it('walks past a stale signed front to a fresher one when a freshness floor is set', async () => {
    const stale = envelopeFor(manifestPayload({ generated_at: '2026-07-01T00:00:00Z' }));
    const fresh = envelopeFor(manifestPayload({ generated_at: '2026-07-22T00:00:00Z' }));
    const fetchMock = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse(stale))
      .mockResolvedValueOnce(manifestResponse(fresh));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://stale/', 'https://fresh/'], {
      atLeastGeneratedAtMs: Date.parse('2026-07-22T00:00:00Z'),
    });
    expect(fetched?.url).toBe('https://fresh/');
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('stops at the first front when it is at least as fresh as the floor (steady state)', async () => {
    const current = envelopeFor(manifestPayload({ generated_at: '2026-07-22T00:00:00Z' }));
    const fetchMock = jest.fn().mockResolvedValue(manifestResponse(current));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://a/', 'https://b/', 'https://c/'], {
      atLeastGeneratedAtMs: Date.parse('2026-07-22T00:00:00Z'),
    });
    expect(fetched?.url).toBe('https://a/');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('returns the newest stale copy when no front meets the floor', async () => {
    const older = envelopeFor(manifestPayload({ generated_at: '2026-07-01T00:00:00Z' }));
    const newer = envelopeFor(manifestPayload({ generated_at: '2026-07-10T00:00:00Z' }));
    globalThis.fetch = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse(older))
      .mockResolvedValueOnce(manifestResponse(newer)) as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://a/', 'https://b/'], {
      atLeastGeneratedAtMs: Date.parse('2026-07-22T00:00:00Z'),
    });
    expect(fetched?.decoded.manifest.generatedAtMs).toBe(Date.parse('2026-07-10T00:00:00Z'));
  });

  it('with no floor (fresh install) surveys every front and takes the newest verified', async () => {
    const older = envelopeFor(manifestPayload({ generated_at: '2026-07-01T00:00:00Z' }));
    const newer = envelopeFor(manifestPayload({ generated_at: '2026-07-10T00:00:00Z' }));
    const fetchMock = jest
      .fn()
      .mockResolvedValueOnce(manifestResponse(older))
      .mockResolvedValueOnce(manifestResponse(newer));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const fetched = await fetchUpdateManifest(['https://a/', 'https://b/']);
    expect(fetched?.url).toBe('https://b/');
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('returns null (never throws) when every candidate fails', async () => {
    globalThis.fetch = jest
      .fn()
      .mockRejectedValue(new Error('offline')) as unknown as typeof fetch;
    await expect(fetchUpdateManifest(['https://a/', 'https://b/'])).resolves.toBeNull();
  });

  it('sends the version headers and cache busters', async () => {
    const fetchMock = jest.fn().mockResolvedValue(manifestResponse(envelopeFor(manifestPayload())));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    await fetchUpdateManifest(['https://a/']);
    const init = fetchMock.mock.calls[0][1] as RequestInit;
    expect(init.headers).toMatchObject({
      'X-OpenRung-App-Version': APP_VERSION,
      'Cache-Control': 'no-cache, no-store',
      Pragma: 'no-cache',
    });
  });
});
