/**
 * Relay descriptor model, ported from the production `model/RelayDescriptor.kt` /
 * `model/RelaySelector.kt`. JSON field names are kept snake_case, exactly as the broker sends them.
 */

export const RelayConstants = {
  PROTOCOL_VLESS_REALITY_VISION: 'vless-reality-vision',
  FLOW_VISION: 'xtls-rprx-vision',
  EXIT_MODE_DIRECT: 'direct',
} as const;

export interface RelayDescriptor {
  id: string;
  label?: string; // friendly relay name (operator-supplied or generated); absent on older brokers
  public_host: string;
  public_port: number;
  protocol: string;
  client_id: string; // VLESS UUID
  reality_public_key: string;
  short_id: string;
  server_name: string; // SNI
  flow: string;
  exit_mode: string;
  max_sessions: number;
  max_mbps: number;
  // Legacy broker wire name; this reports the software version for every relay class.
  volunteer_version: string;
  transport?: 'direct' | 'tunnel';
  punch_capable?: boolean;
  punch_endpoint?: string;
  registered_at: string; // ISO instant
  last_heartbeat_at: string;
  expires_at: string;
  // Broker-served exit location (docs/api.md "List Relays"), city-level accurate at best.
  // All five are absent until the broker's geo lookup succeeds — older brokers never send
  // them. For tunnel (CGNAT) relays this is where traffic actually exits, which is NOT
  // public_host (the relay hub) — never geolocate public_host client-side.
  city?: string;
  country?: string;
  country_code?: string; // ISO 3166-1 alpha-2, uppercase
  latitude?: number; // WGS84
  longitude?: number;
}

export interface RelayListResponse {
  count: number;
  server_time: string;
  relays: RelayDescriptor[];
  // Relay-list signing fields (SPEC v1 §2.2), absent on pre-signing brokers. They live INSIDE the
  // signed body (never in headers) so an attacker cannot rewrite them; net/brokerClient.ts checks
  // them after the Ed25519 signature over the raw body bytes has verified.
  not_after?: string; // RFC3339 freshness bound: server_time + 30 min on the API channel
  key_id?: string; // advisory id of the signing key (first 8 bytes of SHA-256 over the raw pubkey)
  channel?: string; // 'api' or 'mirror' — binds the body to the channel it was fetched from
  limit?: number; // API channel only: echo of the effective request limit
}

export interface ErrorResponse {
  error?: string;
}

function isNotBlank(value: string): boolean {
  return value.trim().length > 0;
}

/**
 * Exact production usability predicate (`RelayDescriptor.isUsable(now)`), with the broker's
 * `server_time` supplied as epoch milliseconds. An unparseable `expires_at` makes the relay
 * unusable (Kotlin's `Instant.parse` failure -> false).
 */
export function isUsable(relay: RelayDescriptor, nowMs: number): boolean {
  const expiresMs = Date.parse(relay.expires_at);
  if (Number.isNaN(expiresMs)) {
    return false;
  }
  return (
    relay.protocol === RelayConstants.PROTOCOL_VLESS_REALITY_VISION &&
    relay.flow === RelayConstants.FLOW_VISION &&
    relay.exit_mode === RelayConstants.EXIT_MODE_DIRECT &&
    expiresMs > nowMs &&
    isNotBlank(relay.public_host) &&
    relay.public_port > 0 &&
    isNotBlank(relay.client_id) &&
    isNotBlank(relay.reality_public_key) &&
    isNotBlank(relay.short_id) &&
    isNotBlank(relay.server_name)
  );
}

/**
 * Broker server time as epoch milliseconds (`RelayListResponse.serverInstant` in production).
 * Throws when `server_time` cannot be parsed, mirroring `Instant.parse`.
 */
export function serverTimeMs(response: RelayListResponse): number {
  const parsed = Date.parse(response.server_time);
  if (Number.isNaN(parsed)) {
    throw new Error(`invalid broker server_time: ${response.server_time}`);
  }
  return parsed;
}

/**
 * `RelaySelector.orderedCandidates`: no client-side scoring — filter to usable relays preserving
 * broker order. Freshness is judged against broker server time, not the device clock.
 */
export function orderedCandidates(relays: RelayDescriptor[], nowMs: number): RelayDescriptor[] {
  return relays.filter(relay => isUsable(relay, nowMs));
}

/** `RelaySelector.selectFirstUsable`: first usable relay in broker order, or null. */
export function selectFirstUsable(relays: RelayDescriptor[], nowMs: number): RelayDescriptor | null {
  return orderedCandidates(relays, nowMs)[0] ?? null;
}
