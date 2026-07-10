/**
 * Relay-list signature verification (SPEC v1 §5.2 / test plan §12): the shared §2.3 vector plus
 * its negative variants, the loopback dev exemption, the pinned-key CI guard (§11), and the
 * text()+TextEncoder byte-identity fallback. Bodies for the constructed cases are signed with the
 * PUBLIC test seed from testdata/signing_vectors.json — the production seeds stay offline.
 */
import * as ed from '@noble/ed25519';

import { AppConfig } from '../../src/config';
import {
  RELAYS_SIGNATURE_HEADER,
  firstReachable,
  listRelays,
  setRelaySigningKeysForTests,
  verifySignedRelayList,
} from '../../src/net/brokerClient';
import {
  TEST_SIGNING_KEY,
  base64ToBytes,
  deriveKeyId,
  signRelayListBody,
  signedApiBody,
  signedResponse,
  signingVectors,
  utf8Bytes,
} from '../helpers/signing';

const VECTOR = signingVectors.spec_vector;
// The vector's not_after is 2026-07-10T00:30:00Z; "now" is 10 min after server_time.
const VECTOR_NOW_MS = Date.parse('2026-07-10T00:10:00Z');
// A second PUBLIC test seed (32 bytes of 0x43) whose key is never pinned anywhere.
const UNPINNED_SEED_B64 = 'Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M=';

beforeEach(() => {
  setRelaySigningKeysForTests([TEST_SIGNING_KEY]);
});

afterEach(() => {
  setRelaySigningKeysForTests(null);
});

describe('verifySignedRelayList (§2.3 vector and variants)', () => {
  const verify = (header: string | null, body: string = VECTOR.body, limit = 1, nowMs = VECTOR_NOW_MS) =>
    verifySignedRelayList(utf8Bytes(body), header, limit, nowMs);

  it('accepts the shared vector verbatim and parses the SAME buffer', () => {
    const { response, keyIdUsed } = verify(VECTOR.header_value);
    expect(keyIdUsed).toBe(VECTOR.key_id);
    expect(response.count).toBe(1);
    expect(response.server_time).toBe('2026-07-10T00:00:00Z');
    expect(response.not_after).toBe('2026-07-10T00:30:00Z');
    expect(response.channel).toBe('api');
    expect(response.limit).toBe(1);
    expect(response.relays).toEqual([]);
  });

  it('accepts a response past not_after but inside the 5-min skew allowance', () => {
    // not_after 00:30 with skew 5 min: acceptance boundary is now = 00:35:00 exactly.
    expect(() => verify(VECTOR.header_value, VECTOR.body, 1, Date.parse('2026-07-10T00:35:00Z'))).not.toThrow();
    expect(() => verify(VECTOR.header_value, VECTOR.body, 1, Date.parse('2026-07-10T00:35:01Z'))).toThrow(
      'unsigned/invalid relay list',
    );
  });

  it('accepts a wrong advisory key_id when the signature verifies under a pinned key (§4.2)', () => {
    // Same 64-byte signature, but the header routes to a key_id no pinned key has: the verifier
    // must fall back to trying every pinned key rather than rejecting.
    const signature = VECTOR.header_value.split(';')[2];
    const { keyIdUsed } = verify(`ed25519;ffffffffffffffff;${signature}`);
    expect(keyIdUsed).toBe(VECTOR.key_id); // reports the PINNED key that verified, not the header's claim
  });

  it('rejects a flipped body byte', () => {
    const tampered = VECTOR.body.replace('"count":1', '"count":2');
    expect(() => verify(VECTOR.header_value, tampered)).toThrow('unsigned/invalid relay list');
  });

  it('rejects a flipped signature byte', () => {
    // First base64 char K -> L still decodes to 64 bytes but is no longer the vector signature.
    const flipped = VECTOR.header_value.replace(/;K/, ';L');
    expect(flipped).not.toBe(VECTOR.header_value);
    expect(() => verify(flipped)).toThrow('unsigned/invalid relay list');
  });

  it('rejects a valid signature under an unpinned key', () => {
    const header = signRelayListBody(VECTOR.body, UNPINNED_SEED_B64);
    expect(() => verify(header)).toThrow('signature does not verify against any pinned key');
  });

  it('rejects a missing header', () => {
    expect(() => verify(null)).toThrow('missing signature header');
    expect(() => verify('')).toThrow('missing signature header');
  });

  it.each([
    ['two fields only', `ed25519;${VECTOR.key_id}`],
    ['four fields', `${VECTOR.header_value};extra`],
    ['wrong algorithm', VECTOR.header_value.replace('ed25519;', 'rsa;')],
    ['bad base64', `ed25519;${VECTOR.key_id};!!!not-base64!!!`],
    // Valid base64 of the first 63 signature bytes — an Ed25519 signature is exactly 64.
    ['truncated signature', `ed25519;${VECTOR.key_id};K5UmJWzoEZ1YHOqZFf5E+ocNOITSe3WPvOo0GuyCRoiAxUk4eo/jcfqiuaPhrNeYrK3i8QcYI3LIv+zbVYq9`],
  ])('rejects a malformed header: %s', (_name, header) => {
    expect(() => verify(header)).toThrow('unsigned/invalid relay list');
  });

  it('rejects an expired not_after on a fresh fetch', () => {
    expect(() => verify(VECTOR.header_value, VECTOR.body, 1, Date.parse('2026-07-10T01:00:00Z'))).toThrow(
      'response expired',
    );
  });

  it('rejects a signed body without not_after', () => {
    const body = signedApiBody({ limit: 1, not_after: undefined }, VECTOR_NOW_MS);
    expect(() => verify(signRelayListBody(body), body, 1)).toThrow('response expired');
  });

  it('rejects a limit-echo mismatch (§2.2 variant-steering defence)', () => {
    expect(() => verify(VECTOR.header_value, VECTOR.body, 2)).toThrow('unsigned/invalid relay list');
  });

  it('rejects a validly signed mirror-channel body cross-fed into the API slot', () => {
    const mirrorBody =
      '{"count":1,"server_time":"2026-07-10T00:00:00Z","not_after":"2026-07-11T00:00:00Z",' +
      `"key_id":"${VECTOR.key_id}","channel":"mirror","relays":[]}`;
    expect(() => verify(signRelayListBody(mirrorBody), mirrorBody)).toThrow('is not "api"');
  });
});

describe('pinned-key CI guard (§11)', () => {
  // A truncated/typo'd pinned constant must fail HERE, not on key-promotion day: each AppConfig
  // key must derive its own key_id and verify the committed promotion vector for that key.
  it('AppConfig.RELAY_SIGNING_KEYS carries exactly the shared active+standby keys, active first', () => {
    expect(AppConfig.RELAY_SIGNING_KEYS.map(key => key.keyId)).toEqual(
      signingVectors.pinned_keys.map(key => key.key_id),
    );
    expect(AppConfig.RELAY_SIGNING_KEYS.map(key => key.publicKeyHex)).toEqual(
      signingVectors.pinned_keys.map(key => key.public_key_hex),
    );
    expect(signingVectors.pinned_keys[0].name).toBe('active');
    expect(signingVectors.pinned_keys[1].name).toBe('standby');
  });

  it.each(AppConfig.RELAY_SIGNING_KEYS.map(key => [key.keyId, key.publicKeyHex]))(
    'pinned key %s: key_id derivation and promotion vector verify against the CONFIG constant',
    (keyId, publicKeyHex) => {
      const publicKey = ed.etc.hexToBytes(publicKeyHex);
      expect(publicKey).toHaveLength(32);
      expect(deriveKeyId(publicKey)).toBe(keyId);
      const vector = signingVectors.pinned_keys.find(key => key.key_id === keyId);
      expect(vector).toBeDefined();
      const verifies = ed.verify(
        base64ToBytes((vector as { vector_signature_b64: string }).vector_signature_b64),
        utf8Bytes((vector as { vector_message: string }).vector_message),
        publicKey,
      );
      expect(verifies).toBe(true);
    },
  );

  it('the §2.3 test key matches its committed derivations', () => {
    const publicKey = ed.getPublicKey(base64ToBytes(VECTOR.seed_b64));
    expect(ed.etc.bytesToHex(publicKey)).toBe(VECTOR.public_key_hex);
    expect(deriveKeyId(publicKey)).toBe(VECTOR.key_id);
    expect(signRelayListBody(VECTOR.body)).toBe(VECTOR.header_value);
  });
});

describe('listRelays verification shim (fetch level)', () => {
  const originalFetch = (globalThis as Record<string, unknown>).fetch;

  function installFetch(impl: (url: string) => Promise<unknown>): jest.Mock {
    const stub = jest.fn(impl);
    (globalThis as Record<string, unknown>).fetch = stub;
    return stub;
  }

  afterEach(() => {
    (globalThis as Record<string, unknown>).fetch = originalFetch;
    jest.useRealTimers();
  });

  it('accepts a correctly signed response from a non-loopback broker', async () => {
    installFetch(async () => signedResponse(signedApiBody({ limit: 5 })));
    const response = await listRelays('https://broker.example/');
    expect(response.channel).toBe('api');
    expect(response.limit).toBe(5);
  });

  it('fails an unsigned 2xx response from a non-loopback broker with the mandated message', async () => {
    installFetch(async () => signedResponse(signedApiBody({ limit: 5 }), { header: null }));
    await expect(listRelays('https://broker.example/')).rejects.toThrow(
      'unsigned/invalid relay list (missing signature header)',
    );
  });

  it('fails a signed response whose echoed limit differs from the request', async () => {
    installFetch(async () => signedResponse(signedApiBody({ limit: 5 })));
    await expect(listRelays('https://broker.example/', { limit: 20 })).rejects.toThrow(
      'unsigned/invalid relay list',
    );
  });

  it.each([
    ['http://127.0.0.1:8080/'],
    ['http://localhost:8080/'],
    ['http://[::1]:8080/'],
  ])('loopback dev broker %s skips verification entirely (unsigned, text-only response)', async url => {
    // Pre-signing stub shape: no signature header, no arrayBuffer, no headers at all — exactly
    // what a local dev broker without a signing key serves.
    installFetch(async () => ({
      status: 200,
      text: async () => JSON.stringify({ count: 0, server_time: '2026-07-10T00:00:00Z', relays: [] }),
    }));
    await expect(listRelays(url)).resolves.toMatchObject({ count: 0 });
  });

  it('a non-loopback plain-IP override still requires a valid signature', async () => {
    installFetch(async () => ({
      status: 200,
      headers: { get: () => null },
      text: async () => JSON.stringify({ count: 0, server_time: '2026-07-10T00:00:00Z', relays: [] }),
    }));
    await expect(listRelays('http://54.238.185.205:8080/')).rejects.toThrow(
      'unsigned/invalid relay list',
    );
  });

  it('text()+TextEncoder fallback is byte-identical to the binary read for the broker output', async () => {
    const body = signedApiBody({ limit: 5 });
    // Byte identity: re-encoding the decoded text equals the raw wire bytes for valid UTF-8.
    // (Jest's Node environment provides the same TextEncoder Hermes ships.)
    const { TextEncoder: NodeTextEncoder } = globalThis as unknown as {
      TextEncoder: new () => { encode(input: string): Uint8Array };
    };
    const viaText = new NodeTextEncoder().encode(body);
    expect(Array.from(viaText)).toEqual(Array.from(utf8Bytes(body)));

    // End to end: a Response WITHOUT arrayBuffer() (RN fallback path) must still verify.
    const full = signedResponse(body);
    installFetch(async () => ({
      status: full.status,
      headers: full.headers,
      text: full.text,
    }));
    await expect(listRelays('https://broker.example/')).resolves.toMatchObject({ limit: 5 });
  });

  it('a verification failure makes the discovery race fall through to the next candidate', async () => {
    jest.useFakeTimers();
    const good = 'https://good.example/';
    installFetch(async (url: string) =>
      url.startsWith(good)
        ? signedResponse(signedApiBody({ limit: 5 }))
        : signedResponse(signedApiBody({ limit: 5 }), { header: null }), // unsigned primary
    );
    const race = firstReachable(['https://stripped.example/', good]);
    await jest.advanceTimersByTimeAsync(AppConfig.DISCOVERY_STAGGER_MS);
    await expect(race).resolves.toMatchObject({ brokerUrl: good });
  });

  it('reads the signature header case-insensitively (HTTP/2 lowercases it)', async () => {
    const body = signedApiBody({ limit: 5 });
    const header = signRelayListBody(body);
    installFetch(async () => ({
      status: 200,
      // A lowercase-only header map: listRelays must still find the value via its Headers.get
      // contract (our mock mirrors Headers' case-insensitive lookup, as fetch guarantees).
      headers: {
        get: (name: string) => (name.toLowerCase() === RELAYS_SIGNATURE_HEADER.toLowerCase() ? header : null),
      },
      arrayBuffer: async () => {
        const bytes = utf8Bytes(body);
        return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      },
      text: async () => body,
    }));
    await expect(listRelays('https://broker.example/')).resolves.toMatchObject({ limit: 5 });
  });
});
