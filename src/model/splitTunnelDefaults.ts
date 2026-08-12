/**
 * Region-aware split-tunnel country defaults.
 *
 * The bundled `geosite-ir` / `geosite-cn` rule sets are only ever a sane default INSIDE those
 * countries. `geosite-cn` in particular carries hosts the whole world loads on ordinary pages
 * (adservice.google.com, doubleclick.net, fonts.googleapis.com, google-analytics.com,
 * www.gstatic.com …): bypassing it outside China resolves and dials those on the direct path and
 * hands the user's real IP to Google while the app reports CONNECTED, and inside China the same
 * bypassed hosts are GFW-blocked and simply fail. So the presets ship on only where they help —
 * Iran + LAN in Iran, China + LAN in China, LAN alone everywhere else — and anyone who wants the
 * other preset can switch it on from the split-tunneling screen.
 *
 * Detection is offline and permission-free (no geo-IP call, no location permission): the IANA
 * time zone first, because it tracks where the device physically is, and a language preference
 * does not — a diaspora phone set to zh-CN in Berlin must NOT get the China preset. The locale's
 * region subtag is only a fallback for devices that report no usable zone.
 */

/**
 * IANA zones that place the device inside a country with a bundled preset, lowercased (both
 * canonical names and the legacy aliases Android/iOS may still report).
 *
 * `Asia/Hong_Kong` and `Asia/Macau` are deliberately absent: neither sits behind the GFW, so the
 * mainland preset would cost them the tunnel without buying reachability.
 */
const REGION_BY_TIME_ZONE: Record<string, string> = {
  'asia/tehran': 'IR',
  iran: 'IR',
  'asia/shanghai': 'CN',
  'asia/chongqing': 'CN',
  'asia/chungking': 'CN',
  'asia/harbin': 'CN',
  'asia/urumqi': 'CN',
  'asia/kashgar': 'CN',
  prc: 'CN',
};

/**
 * The device's IANA time zone, lowercased — or '' when it carries no location at all (missing,
 * or one of the placeholder zones a device reports when it has none).
 */
function deviceTimeZone(): string {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (typeof zone !== 'string') {
      return '';
    }
    const lower = zone.trim().toLowerCase();
    if (lower === 'utc' || lower === 'gmt' || lower === 'local' || lower.startsWith('etc/')) {
      return '';
    }
    return lower;
  } catch {
    return '';
  }
}

/**
 * ISO-3166 region subtag of the system locale ('fa-IR' → 'IR', 'zh-Hans-CN' → 'CN'), or '' when
 * the locale carries none ('fa'). Scanning stops at the first one-character subtag: everything
 * past that singleton is an extension ('en-US-u-ca-persian'), where two-letter keys are not
 * regions.
 */
function localeRegion(): string {
  try {
    const locale = Intl.DateTimeFormat().resolvedOptions().locale;
    if (typeof locale !== 'string') {
      return '';
    }
    const subtags = locale.split('-');
    for (let index = 1; index < subtags.length; index++) {
      const subtag = subtags[index];
      if (subtag.length === 1) {
        break;
      }
      if (/^[A-Za-z]{2}$/.test(subtag)) {
        return subtag.toUpperCase();
      }
    }
    return '';
  } catch {
    return '';
  }
}

/**
 * Best-effort ISO-3166 region for the device, or '' when nothing usable is available.
 *
 * A specific time zone is authoritative in BOTH directions: 'America/Los_Angeles' means the
 * device is not in Iran or China even when the locale claims fa-IR or zh-CN. Only a device
 * reporting no real zone falls back to the locale.
 */
export function deviceRegion(): string {
  const zone = deviceTimeZone();
  if (zone !== '') {
    return REGION_BY_TIME_ZONE[zone] ?? '';
  }
  return localeRegion();
}

/** Bypass-country presets for an ISO-3166 region; empty for everywhere without a bundled set. */
export function bypassCountriesForRegion(region: string): string[] {
  switch (region.toUpperCase()) {
    case 'IR':
      return ['ir'];
    case 'CN':
      return ['cn'];
    default:
      return [];
  }
}

/** Country presets a fresh install should start with on this device. */
export function defaultBypassCountries(): string[] {
  return bypassCountriesForRegion(deviceRegion());
}
