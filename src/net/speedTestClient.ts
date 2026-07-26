import { runSpeedTest as nativeRunSpeedTest } from '../native/OpenRungBroker';

/** Existing Settings-screen result model. */
export interface SpeedTestResult {
  bytesDownloaded: number;
  durationMs: number;
  timeToFirstByteMs: number;
  downloadMbps: number;
}

/**
 * Runs brokerapi's native warmup + measurement flow. Total duration intentionally maps to the
 * existing `durationMs` field because brokerapi computes Mbps over the complete measured request.
 */
export async function runSpeedTest(
  brokerUrl: string,
  signal?: AbortSignal,
): Promise<SpeedTestResult> {
  const result = await nativeRunSpeedTest({ brokerUrl }, signal);
  return {
    bytesDownloaded: result.bytes,
    durationMs: result.totalDurationMillis,
    timeToFirstByteMs: result.ttfbMillis,
    downloadMbps: result.mbps,
  };
}
