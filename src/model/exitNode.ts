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
}

/** Load state of the exit-node map directory (the list of available exit-node regions). */
export type DirectoryStatus = 'idle' | 'loading' | 'loaded' | 'failed';
