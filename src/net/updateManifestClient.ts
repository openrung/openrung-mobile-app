/* eslint-disable no-bitwise -- the base64/UTF-8 codecs below are inherently byte-twiddling */
import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha2.js';
import { Platform } from 'react-native';

import { APP_VERSION, AppConfig } from '../config';

// Hermes has no SubtleCrypto, so @noble/ed25519's async (WebCrypto-hashed) path is unavailable;
// wiring the pure-JS SHA-512 enables the sync verify path (same wiring as brokerClient.ts).
ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

/**
 * In-app update manifest client (docs/UPDATE_MANIFEST.md). Fetches the signed envelope from the
 * ordered candidate URLs, verifies the detached Ed25519 signature over the exact payload bytes
 * against the pinned MANIFEST_SIGNING_KEYS, and decodes the payload LENIENTLY: the manifest URL +
 * schema are a forever-contract with shipped clients, so unknown fields are ignored and invalid
 * optional fields degrade to null instead of failing the whole document.
 *
 * Trust model: `verified` is the only trust signal. An unsigned envelope still decodes
 * (verified=false) — the derivation layer caps it at the passive "update available" tier — but a
 * PRESENT-and-invalid signature throws, so a tampered copy on one CDN front fails that candidate
 * and a clean copy from the next one can win. Nothing here ever blocks the app on its own:
 * all-candidates-fail just returns null (fail open, per the availability-first design).
 */

const REQUEST_TIMEOUT_MS = 10_000;

export interface UpdatePlatformInfo {
  /** Latest released version ("x.y.z"), or null if absent/unparseable. */
  latest: string | null;
  /** Versions below this cannot work anymore ("x.y.z"); null = no floor. */
  minSupported: string | null;
}

export interface UpdateNotice {
  /** Dismissal key — re-broadcast by changing the id. */
  id: string;
  level: 'info' | 'warn';
  /** {locale: text}; 'en' is guaranteed present. */
  title: Record<string, string>;
  body: Record<string, string>;
  /** Optional https "Learn more" target (only ever opened from VERIFIED manifests). */
  url: string | null;
  /** Epoch ms after which the notice is hidden client-side; null = no expiry. */
  expiresMs: number | null;
}

export interface UpdateManifest {
  /** Epoch ms the manifest was generated (0 when absent) — used for rollback monotonicity. */
  generatedAtMs: number;
  android: UpdatePlatformInfo | null;
  ios: UpdatePlatformInfo | null;
  promote: 'silent' | 'notify';
  notice: UpdateNotice | null;
}

export interface DecodedUpdateManifest {
  manifest: UpdateManifest;
  /** True only when a signature was present AND verified against a pinned key. */
  verified: boolean;
  keyIdUsed: string | null;
}

export interface ManifestSigningKey {
  keyId: string;
  publicKeyHex: string;
}

// Pinned-key override for tests only (same convention as setRelaySigningKeysForTests).
let signingKeysOverride: readonly ManifestSigningKey[] | null = null;

export function setManifestSigningKeysForTests(keys: readonly ManifestSigningKey[] | null): void {
  signingKeysOverride = keys;
}

function pinnedSigningKeys(): readonly ManifestSigningKey[] {
  return signingKeysOverride ?? AppConfig.MANIFEST_SIGNING_KEYS;
}

function manifestFailure(reason: string): Error {
  return new Error(`update manifest: invalid (${reason})`);
}

// --- byte codecs ------------------------------------------------------------------------------
// Duplicated from brokerClient.ts internals (which are deliberately unexported and spec-pinned):
// Hermes has no atob, and TextDecoder may be absent.

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Strict standard-base64 (padded) decoder; throws on any deviation. */
function base64ToBytes(encoded: string): Uint8Array {
  if (encoded.length === 0 || encoded.length % 4 !== 0) {
    throw manifestFailure('not valid base64');
  }
  const padding = encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0;
  const out = new Uint8Array((encoded.length / 4) * 3 - padding);
  let buffer = 0;
  let bits = 0;
  let outIndex = 0;
  for (let i = 0; i < encoded.length - padding; i++) {
    const value = BASE64_ALPHABET.indexOf(encoded[i]);
    if (value < 0) {
      throw manifestFailure('not valid base64');
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

type TextCodecGlobals = {
  TextDecoder?: new (label?: string, options?: { fatal?: boolean }) => {
    decode(input: Uint8Array): string;
  };
};

/** Strict UTF-8 decode of the VERIFIED payload bytes; invalid UTF-8 throws. */
function decodeUtf8(bytes: Uint8Array): string {
  const codecs = globalThis as TextCodecGlobals;
  if (codecs.TextDecoder) {
    try {
      return new codecs.TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch {
      throw manifestFailure('payload is not valid UTF-8');
    }
  }
  let out = '';
  let i = 0;
  const fail = () => manifestFailure('payload is not valid UTF-8');
  while (i < bytes.length) {
    const b0 = bytes[i++];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      continue;
    }
    let extra: number;
    let codePoint: number;
    let min: number;
    if (b0 >= 0xc2 && b0 <= 0xdf) {
      extra = 1;
      codePoint = b0 & 0x1f;
      min = 0x80;
    } else if (b0 >= 0xe0 && b0 <= 0xef) {
      extra = 2;
      codePoint = b0 & 0x0f;
      min = 0x800;
    } else if (b0 >= 0xf0 && b0 <= 0xf4) {
      extra = 3;
      codePoint = b0 & 0x07;
      min = 0x10000;
    } else {
      throw fail();
    }
    if (i + extra > bytes.length) {
      throw fail();
    }
    for (let k = 0; k < extra; k++) {
      const next = bytes[i++];
      if ((next & 0xc0) !== 0x80) {
        throw fail();
      }
      codePoint = (codePoint << 6) | (next & 0x3f);
    }
    if (codePoint < min || codePoint > 0x10ffff || (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
      throw fail();
    }
    out += String.fromCodePoint(codePoint);
  }
  return out;
}

// --- version comparison -----------------------------------------------------------------------

const SEMVER_RE = /^\d+\.\d+\.\d+$/;

/**
 * Strict "x.y.z" comparison: -1 / 0 / 1, or null when either side is unparseable — callers must
 * treat null as "no conclusion" (fail open), never as "behind".
 */
export function compareVersions(a: string, b: string): -1 | 0 | 1 | null {
  if (!SEMVER_RE.test(a) || !SEMVER_RE.test(b)) {
    return null;
  }
  const ta = a.split('.').map(Number);
  const tb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if (ta[i] !== tb[i]) {
      return ta[i] < tb[i] ? -1 : 1;
    }
  }
  return 0;
}

// --- decoding ---------------------------------------------------------------------------------

function asSemver(value: unknown): string | null {
  return typeof value === 'string' && SEMVER_RE.test(value) ? value : null;
}

function decodePlatform(value: unknown): UpdatePlatformInfo | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return null;
  }
  const record = value as Record<string, unknown>;
  const latest = asSemver(record.latest);
  const minSupported = asSemver(record.min_supported);
  return latest === null && minSupported === null ? null : { latest, minSupported };
}

function decodeLocalizedMap(value: unknown): Record<string, string> | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return null;
  }
  const out: Record<string, string> = {};
  for (const [locale, text] of Object.entries(value as Record<string, unknown>)) {
    if (typeof text === 'string' && text.trim().length > 0) {
      out[locale] = text;
    }
  }
  return typeof out.en === 'string' ? out : null;
}

function decodeNotice(value: unknown): UpdateNotice | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return null;
  }
  const record = value as Record<string, unknown>;
  const id = typeof record.id === 'string' && record.id.trim().length > 0 ? record.id : null;
  const title = decodeLocalizedMap(record.title);
  const body = decodeLocalizedMap(record.body);
  if (id === null || title === null || body === null) {
    return null;
  }
  const expiresMs =
    typeof record.expires === 'string' && !Number.isNaN(Date.parse(record.expires))
      ? Date.parse(record.expires)
      : null;
  return {
    id,
    // Forward-compat: an unknown future level renders as the mildest style instead of vanishing.
    level: record.level === 'warn' ? 'warn' : 'info',
    title,
    body,
    url: typeof record.url === 'string' && record.url.startsWith('https://') ? record.url : null,
    expiresMs,
  };
}

/** Parses `ed25519;<key_id>;<base64_std_signature>` (same 3-field format as the relay header). */
function parseSigField(value: string): { keyId: string; signature: Uint8Array } {
  const fields = value.split(';');
  if (fields.length !== 3 || fields[0] !== 'ed25519') {
    throw manifestFailure('malformed sig field');
  }
  const signature = base64ToBytes(fields[2]);
  if (signature.length !== 64) {
    throw manifestFailure('signature must be 64 bytes');
  }
  return { keyId: fields[1], signature };
}

/**
 * Decodes (and, when a signature is present, verifies) one raw envelope body. Throws on anything
 * structurally broken or on a signature that FAILS verification — the fetch loop treats a throw
 * as "this candidate is bad, try the next". A missing signature is not an error: it yields
 * verified=false, which the derivation layer caps at the passive tier.
 */
export function decodeUpdateEnvelope(raw: string): DecodedUpdateManifest {
  let envelope: unknown;
  try {
    envelope = JSON.parse(raw);
  } catch {
    throw manifestFailure('envelope is not JSON');
  }
  if (typeof envelope !== 'object' || envelope === null || Array.isArray(envelope)) {
    throw manifestFailure('envelope is not an object');
  }
  const envelopeRecord = envelope as Record<string, unknown>;
  if (envelopeRecord.schema !== 1) {
    throw manifestFailure(`unsupported envelope schema ${JSON.stringify(envelopeRecord.schema)}`);
  }
  if (typeof envelopeRecord.payload_b64 !== 'string') {
    throw manifestFailure('payload_b64 missing');
  }
  const payloadBytes = base64ToBytes(envelopeRecord.payload_b64);

  let verified = false;
  let keyIdUsed: string | null = null;
  const sigField = envelopeRecord.sig;
  if (sigField !== undefined && sigField !== null) {
    // A PRESENT sig field must be a well-formed signature: an empty or non-string sig is a
    // mangled/stripped copy, and failing this candidate lets a clean copy on the next front win.
    // Only a genuinely ABSENT sig decodes as unsigned.
    if (typeof sigField !== 'string' || sigField.length === 0) {
      throw manifestFailure('malformed sig field');
    }
    const { keyId, signature } = parseSigField(sigField);
    // The sig key_id is advisory routing only: try the matching pinned key first, then the rest.
    const keys = pinnedSigningKeys();
    const ordered = [
      ...keys.filter(key => key.keyId === keyId),
      ...keys.filter(key => key.keyId !== keyId),
    ];
    for (const key of ordered) {
      try {
        if (ed.verify(signature, payloadBytes, ed.etc.hexToBytes(key.publicKeyHex))) {
          keyIdUsed = key.keyId;
          break;
        }
      } catch {
        // Malformed point/scalar encodings throw in @noble/ed25519; same as verify=false.
      }
    }
    if (keyIdUsed === null) {
      throw manifestFailure('signature does not verify against any pinned key');
    }
    verified = true;
  }

  // Parse the SAME buffer the signature covered.
  let payload: unknown;
  try {
    payload = JSON.parse(decodeUtf8(payloadBytes));
  } catch (error) {
    throw error instanceof Error && error.message.startsWith('update manifest')
      ? error
      : manifestFailure('payload is not JSON');
  }
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) {
    throw manifestFailure('payload is not an object');
  }
  const record = payload as Record<string, unknown>;
  if (record.schema !== 1) {
    throw manifestFailure(`unsupported payload schema ${JSON.stringify(record.schema)}`);
  }

  const generatedAt =
    typeof record.generated_at === 'string' ? Date.parse(record.generated_at) : Number.NaN;
  return {
    manifest: {
      generatedAtMs: Number.isNaN(generatedAt) ? 0 : generatedAt,
      android: decodePlatform(record.android),
      ios: decodePlatform(record.ios),
      promote: record.promote === 'notify' ? 'notify' : 'silent',
      notice: decodeNotice(record.notice),
    },
    verified,
    keyIdUsed,
  };
}

// --- fetching ---------------------------------------------------------------------------------

export interface FetchedUpdateManifest {
  url: string;
  /** The raw envelope body — persisted verbatim so hydration re-verifies the signature. */
  raw: string;
  decoded: DecodedUpdateManifest;
}

async function fetchAttempt(url: string): Promise<FetchedUpdateManifest> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'X-OpenRung-App-Version': APP_VERSION,
        'X-OpenRung-RN': Platform.OS,
        // Same OkHttp-cache reasoning as the relay list: without this, the platform HTTP cache
        // replays a stale manifest and a freshly published floor/notice never arrives.
        'Cache-Control': 'no-cache, no-store',
        Pragma: 'no-cache',
      },
      signal: controller.signal,
    });
    if (response.status < 200 || response.status > 299) {
      throw manifestFailure(`HTTP ${response.status}`);
    }
    const raw = await response.text();
    return { url, raw, decoded: decodeUpdateEnvelope(raw) };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Tries each candidate URL in order (10s per attempt) and returns the first VERIFIED envelope; an
 * unsigned-but-decodable envelope is remembered as a fallback but the walk continues, so a front
 * serving a sig-stripped copy cannot shadow the signed copy on a later front. Returns the
 * unsigned fallback only when no candidate verifies, and null when every candidate fails. Never
 * throws: this is a background check and MUST fail open — no update UI is always an acceptable
 * outcome, a blocked or delayed app never is. Sequential (not the discovery stagger-race) because
 * latency is irrelevant here and order keeps the censorship-resistant fronts preferred.
 */
export async function fetchUpdateManifest(
  urls: readonly string[] = AppConfig.UPDATE_MANIFEST_URLS,
): Promise<FetchedUpdateManifest | null> {
  let unsignedFallback: FetchedUpdateManifest | null = null;
  for (const url of urls) {
    try {
      const fetched = await fetchAttempt(url);
      if (fetched.decoded.verified) {
        return fetched;
      }
      unsignedFallback = unsignedFallback ?? fetched;
    } catch {
      // Failed candidate (network, HTTP status, tampered signature, bad envelope) — try the next.
    }
  }
  return unsignedFallback;
}
