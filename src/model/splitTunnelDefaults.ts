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
 * The IANA time zone is the ONLY evidence used, and it is offline and permission-free (no geo-IP
 * call, no location permission). Deliberately no locale fallback: a language preference is not
 * evidence of physical location — a phone set to zh-CN is just as likely to be in Berlin as in
 * Shanghai — and guessing from it would put the China preset on exactly the diaspora devices this
 * module exists to protect. When the zone carries no location, the answer is no preset, which
 * costs one tap and leaks nothing.
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
 * Best-effort ISO-3166 region for the device, or '' when the time zone gives no usable answer.
 *
 * A real zone is authoritative in BOTH directions: `Asia/Tehran` means Iran even on a phone set
 * to English, and `America/Los_Angeles` means the device is NOT in Iran or China no matter what
 * the locale claims. '' means "no location evidence", never "somewhere we should guess at".
 */
export function deviceRegion(): string {
  return REGION_BY_TIME_ZONE[deviceTimeZone()] ?? '';
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
