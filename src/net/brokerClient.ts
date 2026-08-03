import {
  firstReachable as nativeFirstReachable,
  OpenRungBrokerError,
} from '../native/OpenRungBroker';
import type { RelayDescriptor, RelayListResponse } from '../model/relay';

/** A verified relay fetch together with the broker endpoint selected by brokerapi. */
export interface Fetch {
  brokerUrl: string;
  response: RelayListResponse;
}

export interface FirstReachableOptions {
  limit?: number;
  clientId: string;
  sessionId?: string | null;
  signal?: AbortSignal;
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
 * Decodes brokerapi's already-verified relay JSON with the existing unknown-key tolerance.
 * Missing required relay fields normalize to empty/zero values and are rejected later by the
 * directory's usability checks; optional broker-served geo fields remain absent.
 */
export function decodeRelayListResponse(body: string): RelayListResponse {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw relayDecodeError();
  }
  if (typeof parsed !== 'object' || parsed === null) {
    throw relayDecodeError();
  }
  const record = parsed as Record<string, unknown>;
  if (!Array.isArray(record.relays) || typeof record.server_time !== 'string') {
    throw relayDecodeError();
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
      node_class: asOptionalString(item.node_class),
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

/**
 * Thin React Native adapter over brokerapi's selector. Go owns candidate construction, override
 * handling, racing, timeouts, relay verification, and transport selection; TypeScript only
 * decodes the copied JSON snapshot into the directory's established data model.
 *
 * `signatureVerified` is ENFORCED here rather than merely carried across the bridge. brokerapi
 * reports false only on its explicit loopback-endpoint development short-circuit; every remote
 * candidate either verifies against a pinned operator key or fails the fetch outright. The
 * directory's `brokerUrl` is fixed to the config default (never user-editable, never loopback),
 * so an unverified snapshot reaching this layer means the invariant broke — draw no map pins
 * from it. Relay verification living in Go must not make this repo silently indifferent to it.
 */
export async function firstReachable(
  primary: string,
  options: FirstReachableOptions,
): Promise<Fetch> {
  const result = await nativeFirstReachable(
    {
      primary,
      limit: options.limit ?? 5,
      clientId: options.clientId,
      sessionId: options.sessionId ?? '',
    },
    options.signal,
  );
  if (!result.signatureVerified) {
    throw relayVerificationError();
  }
  return {
    brokerUrl: result.brokerUrl,
    response: decodeRelayListResponse(result.relayJson),
  };
}

function relayDecodeError(): OpenRungBrokerError {
  return new OpenRungBrokerError('decode', 'The native relay directory could not be decoded.');
}

function relayVerificationError(): OpenRungBrokerError {
  return new OpenRungBrokerError(
    'verification',
    'The native relay directory was not signature-verified.',
  );
}
