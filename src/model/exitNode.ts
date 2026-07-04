/**
 * One country/region on the exit-node map. Volunteer relays are grouped by the country resolved
 * for their public host, so a single marker may stand for several nodes (`nodeCount`).
 * Ported from the production `model/ExitNode.kt` / `state/ConnectionStatus.kt`.
 */
export interface ExitNodeRegion {
  countryCode: string;
  countryName: string;
  latitude: number;
  longitude: number;
  nodeCount: number;
}

/** Load state of the exit-node map directory (the list of available exit-node regions). */
export type DirectoryStatus = 'idle' | 'loading' | 'loaded' | 'failed';
