import { Platform } from 'react-native';
import { APP_VERSION } from '../config';
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

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function asNumber(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/**
 * Decodes a relay-list body with unknown-keys tolerance (production uses
 * `Json { ignoreUnknownKeys = true }`); missing relay fields normalise to ''/0, which the
 * `isUsable` predicate then rejects.
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
}

/**
 * GET {base}/api/v1/relays?limit=N. No auth token — the X-OpenRung-* headers are the only
 * identification, exactly like production (plus X-OpenRung-RN marking the RN prototype platform).
 */
export async function listRelays(
  baseUrl: string,
  options: ListRelaysOptions = {},
): Promise<RelayListResponse> {
  const { limit = 5, clientId = null, sessionId = null } = options;
  const url = relayListUrl(baseUrl, limit);
  const headers: Record<string, string> = {
    'X-OpenRung-App-Version': APP_VERSION,
    'X-OpenRung-RN': Platform.OS,
  };
  if (clientId) {
    headers['X-OpenRung-Client-ID'] = clientId;
  }
  if (sessionId) {
    headers['X-OpenRung-Session-ID'] = sessionId;
  }

  const response = await fetchWithTimeout(url, { method: 'GET', headers }, REQUEST_TIMEOUT_MS);
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
 * Fetches relays from each candidate broker in order, returning the first success along with the
 * endpoint that served it. A blocked or down primary endpoint therefore never takes discovery
 * offline as long as one candidate is reachable. If every candidate fails, the last error is
 * rethrown.
 */
export async function firstReachable(
  candidateUrls: string[],
  options: ListRelaysOptions = {},
): Promise<Fetch> {
  if (candidateUrls.length === 0) {
    throw new Error('no broker endpoints configured');
  }
  let lastError: unknown = null;
  for (const url of candidateUrls) {
    try {
      const response = await listRelays(url, options);
      return { brokerUrl: url, response };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error('no broker endpoints reachable');
}
