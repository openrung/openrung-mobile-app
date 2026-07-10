/* eslint-disable no-bitwise -- the base64/UTF-8 codecs below are inherently byte-twiddling */
import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha2.js';
import { Platform } from 'react-native';
// AppConfig is only dereferenced at call time (never during module evaluation), which keeps the
// existing config.ts <-> brokerClient.ts import cycle harmless, same as APP_VERSION below.
import { APP_VERSION, AppConfig } from '../config';
import type { RelayDescriptor, RelayListResponse } from '../model/relay';

// Hermes has no SubtleCrypto, so @noble/ed25519's async (WebCrypto-hashed) path is unavailable;
// wiring the pure-JS SHA-512 enables the sync verify path (SPEC v1 §5.3, React Native row).
ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

/**
 * Broker relay-list client, ported from the production `net/BrokerClient.kt`.
 *
 * Production uses HttpURLConnection with connect 10s / read 15s timeouts; RN `fetch` has no
 * separate connect timeout, so the whole request is bounded by a single 15s AbortController
 * deadline instead.
 */
const REQUEST_TIMEOUT_MS = 15_000;

/** Response header carrying `ed25519;<key_id>;<base64_std_signature>` (SPEC v1 §2.1). */
export const RELAYS_SIGNATURE_HEADER = 'X-OpenRung-Relays-Signature';

/**
 * How far past `not_after` a response is still accepted, covering slow device clocks
 * (SPEC v1 §5.2: `not_after` >= now - 5 min).
 */
const SIGNATURE_SKEW_MS = 5 * 60_000;

/** A successful relay fetch together with the broker endpoint that served it. */
export interface Fetch {
  brokerUrl: string;
  response: RelayListResponse;
}

interface ParsedBase {
  scheme: string;
  authority: string; // userinfo@host:port, preserved verbatim
  path: string;
  query: string | null;
}

/**
 * Minimal scheme://authority/path?query parser. Deliberately avoids WHATWG `URL` /
 * `URLSearchParams`, which are incomplete on React Native's Hermes runtime.
 */
function parseBase(baseUrl: string): ParsedBase {
  const trimmed = baseUrl.trim();
  if (!trimmed) {
    throw new Error('broker URL is required');
  }
  const match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]+)([^?#]*)(?:\?([^#]*))?/.exec(trimmed);
  if (!match || !match[2]) {
    throw new Error('broker URL must include scheme and host');
  }
  return {
    scheme: match[1],
    authority: match[2],
    path: match[3] ?? '',
    query: match[4] ?? null,
  };
}

function joinApiPath(basePath: string, apiPath: string): string {
  const stripped = basePath.replace(/^\/+/, '').replace(/\/+$/, '');
  const segments = [stripped, apiPath].filter(segment => segment.length > 0);
  return '/' + segments.join('/');
}

/**
 * The limit actually sent on the wire: `limit < 1` coerces to the production default of 5.
 * Shared by `relayListUrl` and the signed `limit`-echo check so they can never disagree.
 */
function effectiveLimit(limit: number): number {
  return limit < 1 ? 5 : limit;
}

/**
 * `BrokerClient.relayListUrl`: joins any existing base path with `api/v1/relays`, strips/replaces
 * any existing `limit` query param, and coerces `limit < 1` to 5.
 */
export function relayListUrl(baseUrl: string, limit: number): string {
  const base = parseBase(baseUrl);
  const relayPath = joinApiPath(base.path, 'api/v1/relays');
  const safeLimit = effectiveLimit(limit);
  const existing = (base.query ?? '')
    .split('&')
    .filter(part => part.length > 0)
    .filter(part => part.split('=')[0] !== 'limit');
  const query = [...existing, `limit=${encodeURIComponent(String(safeLimit))}`].join('&');
  return `${base.scheme}://${base.authority}${relayPath}?${query}`;
}

/**
 * Builds the ordered broker candidate list, de-duplicated while preserving order. A non-blank
 * `primary` is tried FIRST only when it is a genuine override — i.e. not already one of the
 * `fallbacks`. A persisted value that merely echoes a built-in default must NOT reorder the
 * defaults' preferred (HTTPS-first) ordering, otherwise an upgrader whose last-used default was
 * the raw IP would keep hitting the IP before the Cloudflare-fronted endpoint. Pure and
 * side-effect free so it is unit-testable.
 */
export function candidates(
  primary: string | null | undefined,
  fallbacks: readonly string[],
): string[] {
  const ordered: string[] = [];
  const seen = new Set<string>();
  const add = (value: string) => {
    if (!seen.has(value)) {
      seen.add(value);
      ordered.push(value);
    }
  };
  const trimmedPrimary = primary?.trim() ?? '';
  if (trimmedPrimary.length > 0 && !fallbacks.some(fallback => fallback.trim() === trimmedPrimary)) {
    add(trimmedPrimary);
  }
  for (const fallback of fallbacks) {
    const trimmed = fallback.trim();
    if (trimmed.length > 0) {
      add(trimmed);
    }
  }
  return ordered;
}

/**
 * `fetch` bounded by BOTH a timeout and an optional external abort signal: whichever fires first
 * aborts the request. The merge is hand-rolled (listen on the outer signal, forward into the
 * request's own controller) because `AbortSignal.any` is not available on RN's Hermes runtime.
 */
async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  signal?: AbortSignal,
): Promise<Response> {
  const controller = new AbortController();
  const onExternalAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) {
      controller.abort();
    } else {
      signal.addEventListener('abort', onExternalAbort);
    }
  }
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onExternalAbort);
  }
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function asNumber(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function asOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function asOptionalNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

/**
 * Decodes a relay-list body with unknown-keys tolerance (production uses
 * `Json { ignoreUnknownKeys = true }`); missing relay fields normalise to ''/0, which the
 * `isUsable` predicate then rejects. The broker-served geo fields are genuinely optional on
 * the wire (omitted until the broker's lookup succeeds), so they stay `undefined` when absent
 * or malformed instead of being normalised.
 */
export function decodeRelayListResponse(body: string): RelayListResponse {
  const parsed: unknown = JSON.parse(body);
  if (typeof parsed !== 'object' || parsed === null) {
    throw new Error('broker list relays: unexpected response shape');
  }
  const record = parsed as Record<string, unknown>;
  if (!Array.isArray(record.relays) || typeof record.server_time !== 'string') {
    throw new Error('broker list relays: unexpected response shape');
  }
  const relays: RelayDescriptor[] = record.relays.map(raw => {
    const item = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>;
    return {
      id: asString(item.id),
      label: asOptionalString(item.label),
      public_host: asString(item.public_host),
      public_port: asNumber(item.public_port),
      protocol: asString(item.protocol),
      client_id: asString(item.client_id),
      reality_public_key: asString(item.reality_public_key),
      short_id: asString(item.short_id),
      server_name: asString(item.server_name),
      flow: asString(item.flow),
      exit_mode: asString(item.exit_mode),
      max_sessions: asNumber(item.max_sessions),
      max_mbps: asNumber(item.max_mbps),
      volunteer_version: asString(item.volunteer_version),
      registered_at: asString(item.registered_at),
      last_heartbeat_at: asString(item.last_heartbeat_at),
      expires_at: asString(item.expires_at),
      city: asOptionalString(item.city),
      country: asOptionalString(item.country),
      country_code: asOptionalString(item.country_code),
      latitude: asOptionalNumber(item.latitude),
      longitude: asOptionalNumber(item.longitude),
    };
  });
  return {
    count: asNumber(record.count),
    server_time: record.server_time,
    relays,
    not_after: asOptionalString(record.not_after),
    key_id: asOptionalString(record.key_id),
    channel: asOptionalString(record.channel),
    limit: asOptionalNumber(record.limit),
  };
}

// ---------------------------------------------------------------------------
// Relay-list signature verification (SPEC v1 §5.2) — the byte-level shim below
// the discovery layer. Signing defends CHANNEL INTEGRITY only: a compromised
// broker still signs whatever it likes, and a censor can still block, strip
// the header, or inject non-2xx responses — all of which degrade to "candidate
// failed, fall through", never to accepting forged data.
// ---------------------------------------------------------------------------

/** A pinned Ed25519 verification key (see AppConfig.RELAY_SIGNING_KEYS for the derivations). */
export interface RelaySigningKey {
  keyId: string;
  publicKeyHex: string;
}

// Pinned-key override for tests only (same convention as store.ts `resetStoreForTests`): the
// production private keys are offline, so tests verify bodies signed with the public SPEC §2.3
// test seed against ITS key instead.
let signingKeysOverride: readonly RelaySigningKey[] | null = null;

export function setRelaySigningKeysForTests(keys: readonly RelaySigningKey[] | null): void {
  signingKeysOverride = keys;
}

function pinnedSigningKeys(): readonly RelaySigningKey[] {
  return signingKeysOverride ?? AppConfig.RELAY_SIGNING_KEYS;
}

/** Host part of a URL authority: strips userinfo, an IPv6 bracket wrapper, and any port. */
function hostOfAuthority(authority: string): string {
  const at = authority.lastIndexOf('@');
  const hostPort = at >= 0 ? authority.slice(at + 1) : authority;
  if (hostPort.startsWith('[')) {
    const end = hostPort.indexOf(']');
    return end >= 0 ? hostPort.slice(1, end) : hostPort;
  }
  const colon = hostPort.indexOf(':');
  return colon >= 0 ? hostPort.slice(0, colon) : hostPort;
}

/** `::`-expanded IPv6 loopback (`::1` and equivalents). IPv4-mapped forms deliberately fail. */
function isIpv6Loopback(host: string): boolean {
  const halves = host.split('::');
  if (halves.length > 2) {
    return false;
  }
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const groups =
    halves.length === 2
      ? [...head, ...Array<string>(Math.max(0, 8 - head.length - tail.length)).fill('0'), ...tail]
      : head;
  if (groups.length !== 8) {
    return false;
  }
  return groups.every(
    (group, index) =>
      /^[0-9a-f]{1,4}$/.test(group) && parseInt(group, 16) === (index === 7 ? 1 : 0),
  );
}

/**
 * Mirrors the desktop client's `hostIsLoopback` (internal/client/broker.go): `localhost` or a
 * loopback IP literal. Loopback brokers are the local dev flow and the ONLY candidates exempt
 * from signature verification; a non-loopback user override still requires a valid signature
 * from the pinned operator keys (self-hosted brokers are unsupported in stock builds).
 */
function isLoopbackHost(host: string): boolean {
  const lower = host.toLowerCase();
  if (lower === 'localhost') {
    return true;
  }
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(lower);
  if (v4) {
    const octets = v4.slice(1).map(Number);
    return octets[0] === 127 && octets.every(octet => octet <= 255);
  }
  return lower.includes(':') && isIpv6Loopback(lower);
}

/**
 * The §5.2 rejection: every verification failure throws (candidate failed) so the discovery race
 * falls through to the next candidate. The message deliberately says "unsigned/invalid relay
 * list" — not a generic network error — per SPEC v1 §5.2.
 */
function signatureFailure(reason: string): Error {
  return new Error(`broker list relays: unsigned/invalid relay list (${reason})`);
}

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/**
 * Strict standard-base64 (padded) decoder. Hand-rolled because Hermes has no `atob`; throws on
 * any character outside the standard alphabet or a non-4-multiple length.
 */
function base64ToBytes(encoded: string): Uint8Array {
  if (encoded.length === 0 || encoded.length % 4 !== 0) {
    throw signatureFailure('signature is not valid base64');
  }
  const padding = encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0;
  const out = new Uint8Array((encoded.length / 4) * 3 - padding);
  let buffer = 0;
  let bits = 0;
  let outIndex = 0;
  for (let i = 0; i < encoded.length - padding; i++) {
    const value = BASE64_ALPHABET.indexOf(encoded[i]);
    if (value < 0) {
      throw signatureFailure('signature is not valid base64');
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

// TextEncoder exists on Hermes (and Node/Jest); TextDecoder may not, so both come with a strict
// pure-JS fallback. Looked up via globalThis because the RN type surface doesn't declare them.
type TextCodecGlobals = {
  TextEncoder?: new () => { encode(input: string): Uint8Array };
  TextDecoder?: new (label?: string, options?: { fatal?: boolean }) => {
    decode(input: Uint8Array): string;
  };
};
const textCodecs = globalThis as TextCodecGlobals;

/**
 * UTF-8 encodes a string. A lone surrogate produces bytes no valid broker body contains, so the
 * subsequent signature check fails closed — matching TextEncoder's replacement behaviour.
 */
function encodeUtf8(text: string): Uint8Array {
  if (textCodecs.TextEncoder) {
    return new textCodecs.TextEncoder().encode(text);
  }
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const code = text.codePointAt(i) as number;
    if (code > 0xffff) {
      i++; // consumed a surrogate pair
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
 * Strict UTF-8 decode of the VERIFIED body bytes ("parse the same buffer", §5.2 step 4). Invalid
 * UTF-8 throws (candidate failed) instead of silently substituting U+FFFD.
 */
function decodeUtf8(bytes: Uint8Array): string {
  if (textCodecs.TextDecoder) {
    return new textCodecs.TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }
  let out = '';
  let i = 0;
  const fail = () => signatureFailure('verified body is not valid UTF-8');
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
      throw fail(); // 0x80-0xc1 (stray continuation / overlong) and 0xf5-0xff
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

interface ParsedSignatureHeader {
  keyId: string;
  signature: Uint8Array;
}

/** Parses `ed25519;<key_id>;<base64_std_signature>` (§2.1: exactly three `;`-separated fields). */
function parseSignatureHeader(value: string): ParsedSignatureHeader {
  const fields = value.split(';');
  if (fields.length !== 3 || fields[0] !== 'ed25519') {
    throw signatureFailure('malformed signature header');
  }
  const signature = base64ToBytes(fields[2]);
  if (signature.length !== 64) {
    throw signatureFailure('signature must be 64 bytes');
  }
  return { keyId: fields[1], signature };
}

/** A verified relay list plus the pinned key that verified it (SPEC v1 §5.1 shim contract). */
export interface VerifiedRelayList {
  response: RelayListResponse;
  /** keyId of the PINNED key that verified — a key_id telemetry signal (§8) in a later phase. */
  keyIdUsed: string;
}

/**
 * The full SPEC v1 §5.2 verification algorithm over the exact raw body bytes of a 2xx API-channel
 * response. Every failure throws "unsigned/invalid relay list" so the calling candidate fails and
 * the discovery race falls through. Exported (with injectable `nowMs`) so the shared
 * testdata/signing_vectors.json cases can drive it directly.
 */
export function verifySignedRelayList(
  bodyBytes: Uint8Array,
  signatureHeader: string | null,
  requestedLimit: number,
  nowMs: number = Date.now(),
): VerifiedRelayList {
  // §5.2 step 2: the header is REQUIRED — a pre-signing broker or a front that strips headers is
  // a failed candidate, never a trusted one.
  if (signatureHeader === null || signatureHeader.length === 0) {
    throw signatureFailure('missing signature header');
  }
  const header = parseSignatureHeader(signatureHeader);

  // §5.2 step 3: verify over the raw bytes. The header key_id is ADVISORY routing only (§4.2):
  // a matching pinned key is tried first, but a mismatch or stale key_id just falls back to
  // trying every pinned key — it costs one wasted verify, not a rejection.
  const keys = pinnedSigningKeys();
  const ordered = [
    ...keys.filter(key => key.keyId === header.keyId),
    ...keys.filter(key => key.keyId !== header.keyId),
  ];
  let keyIdUsed: string | null = null;
  for (const key of ordered) {
    try {
      if (ed.verify(header.signature, bodyBytes, ed.etc.hexToBytes(key.publicKeyHex))) {
        keyIdUsed = key.keyId;
        break;
      }
    } catch {
      // Malformed point/scalar encodings throw in @noble/ed25519; same outcome as verify=false.
    }
  }
  if (keyIdUsed === null) {
    throw signatureFailure('signature does not verify against any pinned key');
  }

  // §5.2 step 4: parse the SAME buffer the signature covered, then check the signed fields.
  const response = decodeRelayListResponse(decodeUtf8(bodyBytes));
  if (response.channel !== 'api') {
    // In-body channel binding (§2.2): a validly signed MIRROR artifact must never be cross-fed
    // into an API-channel slot.
    throw signatureFailure(`channel ${JSON.stringify(response.channel ?? null)} is not "api"`);
  }
  if (response.limit !== requestedLimit) {
    // The signed limit echo kills variant steering: a cached/replayed body for a different
    // `limit` is same-URL CDN-cache-equivalent or nothing.
    throw signatureFailure(`signed limit ${response.limit ?? 'absent'} != requested ${requestedLimit}`);
  }
  const notAfterMs = Date.parse(response.not_after ?? '');
  if (Number.isNaN(notAfterMs) || notAfterMs < nowMs - SIGNATURE_SKEW_MS) {
    throw signatureFailure(`response expired (not_after ${response.not_after ?? 'absent'})`);
  }
  return { response, keyIdUsed };
}

/**
 * Raw body bytes for signature verification: binary read (`arrayBuffer`) preferred; where RN's
 * fetch lacks it, `text()` + UTF-8 re-encode is byte-identical for the broker's valid-UTF-8
 * output and fails closed otherwise (SPEC v1 §5.1 RN exception).
 */
async function readBodyBytes(response: Response): Promise<Uint8Array> {
  if (typeof response.arrayBuffer === 'function') {
    return new Uint8Array(await response.arrayBuffer());
  }
  return encodeUtf8(await response.text());
}

export interface ListRelaysOptions {
  limit?: number;
  clientId?: string | null;
  sessionId?: string | null;
  /**
   * Optional external abort, merged with the per-request 15 s timeout — the underlying fetch is
   * cancelled by whichever fires first. `firstReachable` threads a per-attempt signal through
   * here so that losing attempts of the discovery race are aborted for real (freeing the socket)
   * rather than left running to their timeout.
   */
  signal?: AbortSignal;
}

/**
 * GET {base}/api/v1/relays?limit=N. No auth token — the X-OpenRung-* headers are the only
 * identification, exactly like production (plus X-OpenRung-RN marking the RN prototype platform).
 *
 * Every 2xx response from a non-loopback broker must carry a valid Ed25519 relay-list signature
 * (verifySignedRelayList above); any signing failure throws, i.e. the candidate fails and the
 * discovery race falls through.
 */
export async function listRelays(
  baseUrl: string,
  options: ListRelaysOptions = {},
): Promise<RelayListResponse> {
  const { limit = 5, clientId = null, sessionId = null, signal } = options;
  const url = relayListUrl(baseUrl, limit);
  const loopback = isLoopbackHost(hostOfAuthority(parseBase(baseUrl).authority));
  const headers: Record<string, string> = {
    'X-OpenRung-App-Version': APP_VERSION,
    'X-OpenRung-RN': Platform.OS,
    // The relay list is real-time data, but the broker edge serves it with a long max-age.
    // Without this, the platform HTTP cache (OkHttp on Android) replays an hours-stale list
    // and newly registered relays never appear until the cache entry ages out.
    'Cache-Control': 'no-cache, no-store',
    Pragma: 'no-cache',
  };
  if (clientId) {
    headers['X-OpenRung-Client-ID'] = clientId;
  }
  if (sessionId) {
    headers['X-OpenRung-Session-ID'] = sessionId;
  }

  const response = await fetchWithTimeout(url, { method: 'GET', headers }, REQUEST_TIMEOUT_MS, signal);
  if (response.status < 200 || response.status > 299) {
    // §5.2 step 1: non-2xx = candidate failed. Error bodies are unsigned by design (§2.1) and
    // only ever feed the diagnostic message — never authenticated broker state (a forged 429 is
    // an availability attack no signature catches).
    const body = await response.text();
    let apiError: string | null = null;
    try {
      const decoded: unknown = JSON.parse(body);
      if (typeof decoded === 'object' && decoded !== null) {
        const error = (decoded as Record<string, unknown>).error;
        if (typeof error === 'string' && error.trim().length > 0) {
          apiError = error;
        }
      }
    } catch {
      // Not a JSON error payload; fall through to the raw body.
    }
    const detail = apiError ?? (body.trim().length > 0 ? body : `HTTP ${response.status}`);
    throw new Error(`broker list relays: ${detail}`);
  }
  if (loopback) {
    // Local dev broker: the sole signature-exempt flow (see isLoopbackHost).
    return decodeRelayListResponse(await response.text());
  }
  const bodyBytes = await readBodyBytes(response);
  // Headers.get matches case-insensitively, as §2.1 requires (HTTP/2/3 lowercase header names).
  const signatureHeader = response.headers.get(RELAYS_SIGNATURE_HEADER);
  // keyIdUsed is intentionally not surfaced further yet — key_id telemetry (§8) is a later phase.
  return verifySignedRelayList(bodyBytes, signatureHeader, effectiveLimit(limit)).response;
}

/**
 * Staggered-race discovery (happy-eyeballs style) across the candidate brokers, returning the
 * first success along with the endpoint that served it. A blocked or blackholed primary front
 * therefore costs one DISCOVERY_STAGGER_MS of extra latency — not a full request timeout —
 * before a fallback front is contacted, and never takes discovery offline as long as one
 * candidate is reachable.
 *
 * Race semantics — MUST stay identical across the desktop Go client, this reference TypeScript
 * implementation, and the Android Kotlin / iOS Swift ports:
 *
 *  1. candidate[0] starts immediately; while no attempt has succeeded yet, every
 *     DISCOVERY_STAGGER_MS the next not-yet-started candidate joins the race. An early FAILURE
 *     does not accelerate the schedule — starts are driven purely by the stagger cadence.
 *  2. The first SUCCESS wins and resolves immediately, aborting every other in-flight attempt.
 *     A later candidate that succeeds first wins even while an earlier-priority attempt is still
 *     pending: candidate order buys a head start in the race, nothing more.
 *  3. The per-attempt timeout is unchanged (REQUEST_TIMEOUT_MS inside listRelays).
 *  4. If EVERY candidate fails, the FIRST candidate's (the primary's) error is rethrown — the
 *     primary's failure is the meaningful diagnostic; later fallbacks' errors are secondary.
 *  5. With a single candidate the observable behavior equals the old sequential loop: one
 *     attempt, no timers beyond its own timeout, its error propagated unchanged.
 *
 * `options` excludes `signal` because the race owns per-attempt cancellation: each attempt gets
 * its own AbortSignal, threaded through listRelays so losing requests are aborted for real.
 */
export function firstReachable(
  candidateUrls: string[],
  options: Omit<ListRelaysOptions, 'signal'> = {},
): Promise<Fetch> {
  if (candidateUrls.length === 0) {
    return Promise.reject(new Error('no broker endpoints configured'));
  }
  return new Promise<Fetch>((resolve, reject) => {
    /** One abort controller per STARTED attempt, index-aligned with candidateUrls. */
    const controllers: AbortController[] = [];
    /** Failure of each settled attempt, index-aligned; errors[0] is the surfaced diagnostic. */
    const errors: unknown[] = [];
    let failures = 0;
    /** True once the race settled: a winner resolved, or every candidate failed. */
    let done = false;
    let staggerTimer: ReturnType<typeof setTimeout> | null = null;

    const finish = (settle: () => void): void => {
      done = true;
      if (staggerTimer !== null) {
        clearTimeout(staggerTimer);
        staggerTimer = null;
      }
      settle();
    };

    const startAttempt = (index: number): void => {
      // Schedule the NEXT candidate one stagger from now. The win path cancels this timer, so
      // later candidates only ever start while no attempt has succeeded yet (spec point 1).
      if (index + 1 < candidateUrls.length) {
        staggerTimer = setTimeout(() => startAttempt(index + 1), AppConfig.DISCOVERY_STAGGER_MS);
      }
      const controller = new AbortController();
      controllers[index] = controller;
      listRelays(candidateUrls[index], { ...options, signal: controller.signal }).then(
        response => {
          if (done) {
            return; // another attempt already won; this success arrived too late
          }
          finish(() => {
            // First success wins: abort every other in-flight attempt for real (spec point 2).
            controllers.forEach((other, otherIndex) => {
              if (otherIndex !== index) {
                other.abort();
              }
            });
            resolve({ brokerUrl: candidateUrls[index], response });
          });
        },
        (error: unknown) => {
          if (done) {
            return; // a loser aborted after the race settled — its abort error is expected noise
          }
          errors[index] = error;
          failures++;
          // The race is only lost once ALL candidates have started and failed. A failure never
          // starts the next candidate early — the stagger cadence alone drives starts.
          if (failures === candidateUrls.length) {
            finish(() => {
              const primaryError = errors[0];
              reject(
                primaryError instanceof Error
                  ? primaryError
                  : new Error('no broker endpoints reachable'),
              );
            });
          }
        },
      );
    };

    startAttempt(0);
  });
}
