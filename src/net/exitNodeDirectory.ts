import { centroid } from '../model/countryGeo';
import type { ExitNodeRegion } from '../model/exitNode';
import { orderedCandidates, serverTimeMs } from '../model/relay';
import type { RelayListResponse } from '../model/relay';
import type { ClientGeoInfo } from './geoIpClient';

/**
 * Builds the exit-node map directory, ported from the production `net/ExitNodeDirectory.kt`:
 * fetches the broker's relay list, resolves each usable relay's country via GeoIP, and groups
 * them into one `ExitNodeRegion` per country (placed at a curated centroid, falling back to the
 * GeoIP coordinate when the country is not in the curated table).
 *
 * Both the relay fetch and the geo lookup are injected so this stays free of network dependencies
 * and is unit-testable.
 */
export interface ExitNodeDirectoryOptions {
  fetchRelays: () => Promise<RelayListResponse>;
  lookupGeo: (host: string) => Promise<ClientGeoInfo | null>;
}

export async function loadExitNodeDirectory(
  options: ExitNodeDirectoryOptions,
): Promise<ExitNodeRegion[]> {
  const response = await options.fetchRelays();
  // Freshness is judged against BROKER server time, never the device clock.
  const usable = orderedCandidates(response.relays, serverTimeMs(response));
  if (usable.length === 0) {
    return [];
  }

  // Resolve each distinct host once, concurrently.
  const distinctHosts = [...new Set(usable.map(relay => relay.public_host))];
  const resolved = await Promise.all(
    distinctHosts.map(async host => [host, await options.lookupGeo(host)] as const),
  );
  const geoByHost = new Map<string, ClientGeoInfo | null>(resolved);

  // Drop relays whose geo could not be resolved or whose country code is blank; group by country.
  const geosByCode = new Map<string, ClientGeoInfo[]>();
  for (const relay of usable) {
    const geo = geoByHost.get(relay.public_host);
    if (!geo) {
      continue;
    }
    const code = geo.countryCode.trim().toUpperCase();
    if (code.length === 0) {
      continue;
    }
    const group = geosByCode.get(code);
    if (group) {
      group.push(geo);
    } else {
      geosByCode.set(code, [geo]);
    }
  }

  const regions: ExitNodeRegion[] = [];
  for (const [code, geos] of geosByCode) {
    const curated = centroid(code);
    const first = geos[0];
    regions.push({
      countryCode: code,
      countryName: curated?.name ?? (first.country.trim().length > 0 ? first.country : code),
      latitude: curated?.latitude ?? first.latitude,
      longitude: curated?.longitude ?? first.longitude,
      nodeCount: geos.length,
    });
  }

  // Sort by node count desc, then country name asc (plain code-unit compare, like Kotlin's thenBy).
  regions.sort((a, b) => {
    if (a.nodeCount !== b.nodeCount) {
      return b.nodeCount - a.nodeCount;
    }
    return a.countryName < b.countryName ? -1 : a.countryName > b.countryName ? 1 : 0;
  });
  return regions;
}
