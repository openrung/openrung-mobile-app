/**
 * One located exit spot on the exit-node map. Volunteer relays are grouped by the broker-served
 * exit location (country + city), so a single marker may stand for several nodes (`nodeCount`).
 * Coordinates come straight from the broker and are city-level accurate at best — the map must
 * not imply street-level precision.
 */
export interface ExitNodeRegion {
  countryCode: string; // ISO 3166-1 alpha-2, uppercase — what tap-to-connect targets
  countryName: string;
  city: string | null; // null when the broker only knows the country
  latitude: number;
  longitude: number;
  nodeCount: number;
  /** A few relay endpoints in this region for TCP latency probing (capped when grouping). */
  probeTargets: Array<{ host: string; port: number }>;
}

/** Load state of the exit-node map directory (the list of available exit-node regions). */
export type DirectoryStatus = 'idle' | 'loading' | 'loaded' | 'failed';

/** Stable key for a region (country + city), shared by the directory, store, and map. */
export function regionKey(region: Pick<ExitNodeRegion, 'countryCode' | 'city'>): string {
  return `${region.countryCode}|${region.city ?? ''}`;
}

/** Latency bucket for map badge colouring. */
export type LatencyQuality = 'good' | 'ok' | 'slow' | 'unreachable';

export interface RegionLatency {
  regionKey: string;
  rttMs: number | null; // null = unreachable
}

export interface LatencyState {
  status: 'idle' | 'running' | 'done' | 'failed';
  results: Record<string, RegionLatency>; // keyed by regionKey()
  testedAtMs: number | null;
}

/** Round-trip time -> quality bucket (thresholds tuned for exit-relay reachability). */
export function latencyQuality(rttMs: number | null): LatencyQuality {
  if (rttMs === null) {
    return 'unreachable';
  }
  if (rttMs < 120) {
    return 'good';
  }
  if (rttMs < 250) {
    return 'ok';
  }
  return 'slow';
}
