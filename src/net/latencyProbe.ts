import { AppConfig } from '../config';
import { regionKey, type ExitNodeRegion, type RegionLatency } from '../model/exitNode';
import { OpenRungVpn } from '../native/OpenRungVpn';
import type { LatencyMeasurement, LatencyTarget } from '../native/types';

/**
 * Runs a native TCP-connect latency probe across the regions' relay endpoints and reduces the
 * per-target results to one RTT per region (the minimum of that region's probes; null only when
 * every probe timed out). The native `measureLatency` is injected so this stays unit-testable.
 *
 * Target ids encode the region so results can be regrouped regardless of native ordering:
 * `${regionKey}#${probeIndex}`.
 */
export type MeasureLatencyFn = (
  targets: LatencyTarget[],
  timeoutMs: number,
) => Promise<LatencyMeasurement>;

const TARGET_SEPARATOR = '#';

export async function runLatencyProbe(
  regions: ExitNodeRegion[],
  measure: MeasureLatencyFn = OpenRungVpn.measureLatency.bind(OpenRungVpn),
): Promise<Record<string, RegionLatency>> {
  const targets: LatencyTarget[] = [];
  for (const region of regions) {
    const key = regionKey(region);
    region.probeTargets.forEach((probe, index) => {
      targets.push({ id: `${key}${TARGET_SEPARATOR}${index}`, host: probe.host, port: probe.port });
    });
  }

  if (targets.length === 0) {
    return {};
  }

  const measurement = await measure(targets, AppConfig.LATENCY_PROBE_TIMEOUT_MS);

  // Best (minimum) reachable RTT per region; a region stays null only if all its probes failed.
  const bestByRegion = new Map<string, number | null>();
  for (const result of measurement.results) {
    const key = result.id.split(TARGET_SEPARATOR)[0];
    const current = bestByRegion.has(key) ? bestByRegion.get(key)! : null;
    if (result.reachable && result.latencyMs !== null) {
      bestByRegion.set(key, current === null ? result.latencyMs : Math.min(current, result.latencyMs));
    } else if (!bestByRegion.has(key)) {
      bestByRegion.set(key, null);
    }
  }

  const results: Record<string, RegionLatency> = {};
  for (const [key, rttMs] of bestByRegion) {
    results[key] = { regionKey: key, rttMs };
  }
  return results;
}
