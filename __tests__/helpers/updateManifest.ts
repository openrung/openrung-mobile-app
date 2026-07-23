/**
 * Update-manifest fixtures shared across suites (NOT a test file — excluded via
 * `testPathIgnorePatterns`). Envelopes are signed with the PUBLIC test seed (32 bytes of 0x55)
 * from testdata/update_manifest_vectors.json; the production seed stays offline.
 */
import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha2.js';

import type { ManifestSigningKey } from '../../src/net/updateManifestClient';
import vectors from '../../testdata/update_manifest_vectors.json';
import { base64ToBytes, bytesToBase64, deriveKeyId, utf8Bytes } from './signing';

// Same wiring as updateManifestClient.ts — @noble/ed25519's sync API needs an explicit SHA-512.
ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

/** The whole shared-vector file, typed structurally via resolveJsonModule. */
export const manifestVectors = vectors;

/** The test key in pinned-key shape, for `setManifestSigningKeysForTests`. */
export const TEST_MANIFEST_KEY: ManifestSigningKey = {
  keyId: vectors.test_key.key_id,
  publicKeyHex: vectors.test_key.public_key_hex,
};

/** A second PUBLIC test seed (32 bytes of 0x43) whose key is never pinned anywhere. */
export const UNPINNED_SEED_B64 = 'Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M=';

/** Builds a payload JSON string with sane defaults; override any top-level field. */
export function manifestPayload(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    schema: 1,
    generated_at: '2026-07-22T00:00:00Z',
    android: { latest: '9.9.9', latest_code: 999, min_supported: '0.0.0' },
    ios: { latest: '9.9.9', min_supported: '0.0.0' },
    promote: 'silent',
    notice: null,
    ...overrides,
  });
}

/**
 * Wraps a payload JSON string in an envelope: signed with the test seed by default, a different
 * seed via `seedB64`, an overridden sig key_id via `keyId`, or unsigned via `omitSig`.
 */
export function envelopeFor(
  payloadJson: string,
  options: { seedB64?: string; keyId?: string; omitSig?: boolean; sig?: string } = {},
): string {
  const payloadBytes = utf8Bytes(payloadJson);
  const payloadB64 = bytesToBase64(payloadBytes);
  if (options.omitSig) {
    return JSON.stringify({ schema: 1, payload_b64: payloadB64 });
  }
  if (options.sig !== undefined) {
    return JSON.stringify({ schema: 1, payload_b64: payloadB64, sig: options.sig });
  }
  const seed = base64ToBytes(options.seedB64 ?? vectors.test_key.seed_b64);
  const keyId = options.keyId ?? deriveKeyId(ed.getPublicKey(seed));
  const signature = ed.sign(payloadBytes, seed);
  return JSON.stringify({
    schema: 1,
    payload_b64: payloadB64,
    sig: `ed25519;${keyId};${bytesToBase64(signature)}`,
  });
}

/** The Response surface fetchUpdateManifest actually touches. */
export interface MockManifestResponse {
  status: number;
  text(): Promise<string>;
}

export function manifestResponse(body: string, status: number = 200): MockManifestResponse {
  return { status, text: async () => body };
}
