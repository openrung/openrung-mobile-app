package com.openrung.net

/**
 * The through-tunnel connectivity-probe targets shared by the startup/health probes and the
 * sing-box emission ([SingBoxConfiguration]). These hostnames are pinned through the proxy by the
 * highest-priority DNS and route rules, so a country-bypass rule set that happens to contain a
 * probe hostname (geosite-cn ships www.gstatic.com) can never route the probe onto the direct
 * path and prove nothing about the tunnel.
 *
 * [PhysicalNetworkProbe][com.openrung.vpn.PhysicalNetworkProbe] deliberately does NOT use these:
 * off-tunnel liveness probes must stay free of OpenRung-identifying hostnames.
 */
object ProbeTargets {
    /** Dedicated probe hostname on OpenRung infrastructure; used for nothing but probing. */
    const val DEDICATED_HOST = "probe.openrung.org"

    /** Third-party fallback so a dedicated-infra outage cannot fail every startup. */
    const val FALLBACK_HOST = "cp.cloudflare.com"

    /** Through-tunnel HTTPS probe endpoints, dedicated hostname first. */
    val TUNNEL_PROBE_URLS = listOf(
        "https://$DEDICATED_HOST/generate_204",
        "https://$FALLBACK_HOST/generate_204",
    )

    /** Every hostname the priority DNS/route rules must capture (suffix match). */
    val RULE_DOMAIN_SUFFIXES = listOf(DEDICATED_HOST, FALLBACK_HOST)

    /** Fresh-DNS probes query `<nonce>.`[DNS_PROBE_QNAME_SUFFIX]; any response proves the path. */
    const val DNS_PROBE_QNAME_SUFFIX = DEDICATED_HOST
}
