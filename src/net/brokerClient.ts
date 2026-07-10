import { Platform } from 'react-native';
// AppConfig is only dereferenced at call time (never during module evaluation), which keeps the
// existing config.ts <-> brokerClient.ts import cycle harmless, same as APP_VERSION below.
import { APP_VERSION, AppConfig } from '../config';
import type { RelayDescriptor, RelayListResponse } from '../model/relay';

/**
 * Broker relay-list client, ported from the production `net/BrokerClient.kt`.
 *
 * Production uses HttpURLConnection with connect 10s / read 15s timeouts; RN `fetch` has no
 * separate connect timeout, so the whole request is bounded by a single 15s AbortController
 * deadline instead.
 */
const REQUEST_TIMEOUT_MS = 15_000;

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
 * `BrokerClient.relayListUrl`: joins any existing base path with `api/v1/relays`, strips/replaces
 * any existing `limit` query param, and coerces `limit < 1` to 5.
 */
export function relayListUrl(baseUrl: string, limit: number): string {
  const base = parseBase(baseUrl);
  const relayPath = joinApiPath(base.path, 'api/v1/relays');
  const safeLimit = limit < 1 ? 5 : limit;
  const existing = (base.query ?? '')
    .split('&')
    .filter(part => part.length > 0)
    .filter(part => part.split('=')[0] !== 'limit');
  const query = [...existing, `limit=${encodeURIComponent(String(safeLimit))}`].join('&');
  return `${base.scheme}://${base.authority}${relayPath}?${query}`;
}

/**
 * The ordered discovery endpoints for one request, plus whether `urls[0]` is a genuine user
 * override. Built by `candidates` and consumed by `firstReachable`; carrying the flag alongside
 * the list keeps the two from being computed inconsistently.
 */
export interface BrokerCandidates {
  urls: string[];
  /**
   * True when `urls[0]` is a genuine user override — a non-blank primary that is not one of the
   * built-in defaults. `firstReachable` then tries it strictly first (full per-attempt timeout)
   * and only races the remaining defaults after it fails, so a custom broker that is merely
   * slower than the stagger is never silently outrun by a default front.
   */
  overrideFirst: boolean;
}

/**
 * Builds the ordered broker candidate list, de-duplicated while preserving order. A non-blank
 * `primary` is tried FIRST only when it is a genuine override — i.e. not already one of the
 * `fallbacks` — and only such an override sets `overrideFirst`, giving it the strict head phase
 * described on {@link BrokerCandidates}. A persisted value that merely echoes a built-in default
 * must NOT reorder the defaults' preferred (HTTPS-first) ordering (or claim the override phase),
 * otherwise an upgrader whose last-used default was the raw IP would keep hitting the IP before
 * the Cloudflare-fronted endpoint. Pure and side-effect free so it is unit-testable.
 */
export function candidates(
  primary: string | null | undefined,
  fallbacks: readonly string[],
): BrokerCandidates {
  const ordered: string[] = [];
  const seen = new Set<string>();
  const add = (value: string) => {
    if (!seen.has(value)) {
      seen.add(value);
      ordered.push(value);
    }
  };
  let overrideFirst = false;
  const trimmedPrimary = primary?.trim() ?? '';
  if (trimmedPrimary.length > 0 && !fallbacks.some(fallback => fallback.trim() === trimmedPrimary)) {
    add(trimmedPrimary);
    overrideFirst = true;
  }
  for (const fallback of fallbacks) {
    const trimmed = fallback.trim();
    if (trimmed.length > 0) {
      add(trimmed);
    }
  }
  return { urls: ordered, overrideFirst };
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
  };
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
 */
export async function listRelays(
  baseUrl: string,
  options: ListRelaysOptions = {},
): Promise<RelayListResponse> {
  const { limit = 5, clientId = null, sessionId = null, signal } = options;
  const url = relayListUrl(baseUrl, limit);
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
  const body = await response.text();
  if (response.status < 200 || response.status > 299) {
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
  return decodeRelayListResponse(body);
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
 *  6. When `candidates.overrideFirst` is set, `urls[0]` is a GENUINE user override and racing it
 *     would betray the user's choice: a custom broker that is merely slower than the stagger
 *     would silently lose to a default front. The override is therefore attempted strictly
 *     first, alone, with its full per-attempt timeout — no default is contacted while it is
 *     pending — and it wins on any success, exactly like the old sequential loop. Only when the
 *     override FAILS does the race of points 1–5 start over the REMAINING candidates (the first
 *     of them immediately, the next one stagger later, and so on). If the override and every
 *     remaining candidate fail, the override's error is rethrown — it is `urls[0]`, so point 4's
 *     diagnostic is unchanged.
 *
 * `options` excludes `signal` because the race owns per-attempt cancellation: each attempt gets
 * its own AbortSignal, threaded through listRelays so losing requests are aborted for real.
 */
export async function firstReachable(
  brokerCandidates: BrokerCandidates,
  options: Omit<ListRelaysOptions, 'signal'> = {},
): Promise<Fetch> {
  const { urls, overrideFirst } = brokerCandidates;
  if (urls.length === 0) {
    throw new Error('no broker endpoints configured');
  }
  if (overrideFirst) {
    let overrideError: unknown;
    try {
      // Strict override phase (spec point 6): one plain attempt, full timeout, no race timers.
      const response = await listRelays(urls[0], options);
      return { brokerUrl: urls[0], response };
    } catch (error: unknown) {
      overrideError = error;
    }
    const surfaced =
      overrideError instanceof Error ? overrideError : new Error('no broker endpoints reachable');
    const remaining = urls.slice(1);
    if (remaining.length === 0) {
      throw surfaced;
    }
    try {
      return await race(remaining, options);
    } catch {
      // All-fail keeps surfacing candidates[0]'s — the override's — error (spec point 4).
      throw surfaced;
    }
  }
  return race(urls, options);
}

/** The staggered-race core behind `firstReachable` (spec points 1–5), sans override handling. */
function race(
  candidateUrls: string[],
  options: Omit<ListRelaysOptions, 'signal'> = {},
): Promise<Fetch> {
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
