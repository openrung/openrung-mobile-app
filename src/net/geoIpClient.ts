/**
 * GeoIP lookup via https://ipwho.is/, ported from the production `net/GeoIpClient.kt`.
 * Production uses 4s connect + 4s read timeouts; RN `fetch` gets a single 4s overall deadline.
 */

export const DEFAULT_ENDPOINT = 'https://ipwho.is/';

const REQUEST_TIMEOUT_MS = 4_000;

export interface ClientGeoInfo {
  ip: string;
  country: string;
  countryCode: string;
  city: string;
  asn: string;
  isp: string;
  organization: string;
  latitude: number;
  longitude: number;
}

/** Telemetry attribute map (blank values filtered), as in production. */
export function telemetryAttributes(geo: ClientGeoInfo): Record<string, string> {
  const entries: Array<[string, string]> = [
    ['client_ip', geo.ip],
    ['country', geo.country],
    ['country_code', geo.countryCode],
    ['city', geo.city],
    ['asn', geo.asn],
    ['isp', geo.isp],
    ['organization', geo.organization],
  ];
  const result: Record<string, string> = {};
  for (const [key, value] of entries) {
    if (value.trim().length > 0) {
      result[key] = value;
    }
  }
  return result;
}

/** Human-readable location such as "Austin, United States", or "" when unknown. */
export function locationLabel(geo: ClientGeoInfo): string {
  return [geo.city, geo.country].filter(part => part.trim().length > 0).join(', ');
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function asNumber(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/** Decodes an ipwho.is response body (unknown keys ignored; `!success || blank ip` is an error). */
export function decodeGeoIpResponse(body: string): ClientGeoInfo {
  const parsed: unknown = JSON.parse(body);
  const record = (typeof parsed === 'object' && parsed !== null ? parsed : {}) as Record<
    string,
    unknown
  >;
  const success = record.success === true;
  const ip = asString(record.ip);
  if (!success || ip.trim().length === 0) {
    throw new Error('geo IP lookup failed');
  }
  const connection = (typeof record.connection === 'object' && record.connection !== null
    ? record.connection
    : {}) as Record<string, unknown>;
  const asn = asNumber(connection.asn);
  return {
    ip,
    country: asString(record.country),
    countryCode: asString(record.country_code),
    city: asString(record.city),
    asn: asn > 0 ? `AS${asn}` : '',
    isp: asString(connection.isp),
    organization: asString(connection.org),
    latitude: asNumber(record.latitude),
    longitude: asNumber(record.longitude),
  };
}

/**
 * Looks up geo info for `ip`, or for the caller's own public IP when `ip` is null/blank.
 */
export async function lookup(
  ip: string | null = null,
  endpoint: string = DEFAULT_ENDPOINT,
): Promise<ClientGeoInfo> {
  const target =
    ip === null || ip.trim().length === 0
      ? endpoint
      : endpoint.replace(/\/+$/, '') + '/' + ip.trim();

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(target, {
      method: 'GET',
      headers: { Accept: 'application/json' },
      signal: controller.signal,
    });
    if (response.status < 200 || response.status > 299) {
      throw new Error(`geo IP HTTP ${response.status}`);
    }
    return decodeGeoIpResponse(await response.text());
  } finally {
    clearTimeout(timer);
  }
}
