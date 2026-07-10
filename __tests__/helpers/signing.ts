/**
 * Relay-list signing fixtures shared across suites (NOT a test file — excluded via
 * `testPathIgnorePatterns`). Bodies are signed with the PUBLIC SPEC v1 §2.3 test seed from
 * testdata/signing_vectors.json, so suites exercise the full verification path without touching
 * any production private key. Self-contained base64/UTF-8 codecs because the RN type surface
 * declares neither `Buffer` nor `TextEncoder`.
 */
/* eslint-disable no-bitwise -- the base64/UTF-8 codecs below are inherently byte-twiddling */
import * as ed from '@noble/ed25519';
import { sha256, sha512 } from '@noble/hashes/sha2.js';

import type { RelaySigningKey } from '../../src/net/brokerClient';
import vectors from '../../testdata/signing_vectors.json';

// Same wiring as brokerClient.ts — @noble/ed25519's sync API needs an explicit SHA-512.
ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

/** The whole shared-vector file, typed structurally via resolveJsonModule. */
export const signingVectors = vectors;

/** The §2.3 test key in pinned-key shape, for `setRelaySigningKeysForTests`. */
export const TEST_SIGNING_KEY: RelaySigningKey = {
  keyId: vectors.spec_vector.key_id,
  publicKeyHex: vectors.spec_vector.public_key_hex,
};

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function base64ToBytes(encoded: string): Uint8Array {
  if (encoded.length % 4 !== 0) {
    throw new Error(`bad test base64: ${encoded}`);
  }
  const padding = encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0;
  const out = new Uint8Array((encoded.length / 4) * 3 - padding);
  let buffer = 0;
  let bits = 0;
  let outIndex = 0;
  for (let i = 0; i < encoded.length - padding; i++) {
    const value = BASE64_ALPHABET.indexOf(encoded[i]);
    if (value < 0) {
      throw new Error(`bad test base64: ${encoded}`);
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[outIndex++] = (buffer >> bits) & 0xff;
    }
  }
  return out;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const chunk = [bytes[i], bytes[i + 1], bytes[i + 2]];
    out += BASE64_ALPHABET[chunk[0] >> 2];
    out += BASE64_ALPHABET[((chunk[0] & 0x03) << 4) | ((chunk[1] ?? 0) >> 4)];
    out += i + 1 < bytes.length ? BASE64_ALPHABET[((chunk[1] & 0x0f) << 2) | ((chunk[2] ?? 0) >> 6)] : '=';
    out += i + 2 < bytes.length ? BASE64_ALPHABET[chunk[2] & 0x3f] : '=';
  }
  return out;
}

/** UTF-8 encode without ambient TextEncoder (test bodies are well-formed strings). */
export function utf8Bytes(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const code = text.codePointAt(i) as number;
    if (code > 0xffff) {
      i++;
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    }
  }
  return Uint8Array.from(out);
}

/**
 * Signs `body` with a base64 seed (default: the §2.3 test seed) and returns the full
 * `X-OpenRung-Relays-Signature` header value, with the signer's real key_id unless overridden.
 */
export function signRelayListBody(
  body: string,
  seedB64: string = vectors.spec_vector.seed_b64,
  keyId?: string,
): string {
  const seed = base64ToBytes(seedB64);
  const headerKeyId = keyId ?? deriveKeyId(ed.getPublicKey(seed));
  const signature = ed.sign(utf8Bytes(body), seed);
  return `ed25519;${headerKeyId};${bytesToBase64(signature)}`;
}

/** key_id derivation (§2.2): lowercase hex of the first 8 bytes of SHA-256 over the raw pubkey. */
export function deriveKeyId(publicKey: Uint8Array): string {
  return ed.etc.bytesToHex(sha256(publicKey).slice(0, 8));
}

/**
 * A signed relay-list body in broker wire shape: the standard fields plus the §2.2 signing
 * fields. `not_after` defaults to `now + 30 min` like the API channel; `limit` must echo what
 * the client under test requested.
 */
export function signedApiBody(
  overrides: Record<string, unknown> & { limit: number },
  nowMs: number = Date.now(),
): string {
  const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  return JSON.stringify({
    count: 0,
    server_time: iso(nowMs),
    not_after: iso(nowMs + 30 * 60_000),
    key_id: vectors.spec_vector.key_id,
    channel: 'api',
    relays: [],
    ...overrides,
  });
}

/** The Response surface listRelays actually touches, with a case-insensitive header lookup. */
export interface MockSignedResponse {
  status: number;
  headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
}

/**
 * A 2xx broker response carrying `body` and its signature header (pass `header: null` to model
 * a pre-signing broker / header-stripping front). Exposes BOTH arrayBuffer() and text() so the
 * client's preferred binary path is what gets exercised.
 */
export function signedResponse(
  body: string,
  options: { header?: string | null; status?: number } = {},
): MockSignedResponse {
  const header = options.header !== undefined ? options.header : signRelayListBody(body);
  const bytes = utf8Bytes(body);
  return {
    status: options.status ?? 200,
    headers: {
      get: (name: string) =>
        name.toLowerCase() === 'x-openrung-relays-signature' ? header : null,
    },
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
    text: async () => body,
  };
}
