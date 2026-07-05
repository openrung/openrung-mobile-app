/**
 * Exit IP lookup for the Settings "Exit IP check". Plain `fetch` — while the VPN is
 * connected the request rides the tunnel, so the endpoint sees (and reports) the
 * relay's egress IP. PRIVACY: callers must only run this on an explicit user tap and
 * only while connected; disconnected it would reveal the user's real IP to the
 * endpoint (see AppConfig.EXIT_IP_INFO_URL).
 *
 * The decoder is tolerant (mirrors brokerClient's style) and parses the ipinfo.io
 * shape: `{ ip, city, region, country, org }` where `org` embeds "AS#### Name".
 */

export interface ExitIpInfo {
  ip: string;
  country: string | null;
  city: string | null;
  org: string | null; // e.g. "AS13335 Cloudflare, Inc."
}

const REQUEST_TIMEOUT_MS = 15_000;

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

export function decodeExitIpInfo(payload: unknown): ExitIpInfo {
  if (typeof payload !== 'object' || payload === null) {
    throw new Error('exit IP response is not an object');
  }
  const record = payload as Record<string, unknown>;
  const ip = asString(record.ip);
  if (ip === null) {
    throw new Error('exit IP response has no ip');
  }
  return {
    ip,
    country: asString(record.country),
    city: asString(record.city),
    org: asString(record.org),
  };
}

export async function fetchExitIpInfo(url: string): Promise<ExitIpInfo> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: { Accept: 'application/json' },
      signal: controller.signal,
    });
    if (response.status < 200 || response.status > 299) {
      throw new Error(`exit IP lookup HTTP ${response.status}`);
    }
    return decodeExitIpInfo(await response.json());
  } finally {
    clearTimeout(timer);
  }
}
