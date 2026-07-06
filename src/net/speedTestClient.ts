/**
 * Volunteer speed test, ported from the production `net/SpeedTestClient.kt`.
 *
 * DOCUMENTED LIMITATION (contract §8): React Native's `fetch` cannot stream the response body
 * progressively, so unlike production (which times from just before the response headers to the
 * final stream read and stamps TTFB on the first `read()`), this port measures:
 *   - `timeToFirstByteMs`: wall time until `fetch` resolves — i.e. response HEADERS arrival, a
 *     slight underestimate of true first-body-byte time;
 *   - `durationMs`: wall time around `fetch` + `arrayBuffer()` — i.e. until the WHOLE body has
 *     been buffered, which is the closest RN equivalent of production's stream-to-end timing.
 */

export interface SpeedTestResult {
  bytesDownloaded: number;
  durationMs: number;
  timeToFirstByteMs: number;
  downloadMbps: number;
}

export const DEFAULT_WARMUP_BYTES = 1_000_000;
export const DEFAULT_MEASUREMENT_BYTES = 10_000_000;

/** Production read timeout is 60s; the whole request is bounded by one AbortController deadline. */
const REQUEST_TIMEOUT_MS = 60_000;

/** `SpeedTestClient.speedTestUrl`: preserves any base path, joins `api/v1/speed-test`. */
export function speedTestUrl(baseUrl: string): string {
  const trimmed = baseUrl.trim();
  const match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]+)([^?#]*)/.exec(trimmed);
  if (!match || !match[2]) {
    throw new Error('broker URL must include scheme and host');
  }
  const basePath = match[3].replace(/^\/+/, '').replace(/\/+$/, '');
  const segments = [basePath, 'api/v1/speed-test'].filter(segment => segment.length > 0);
  return `${match[1]}://${match[2]}/${segments.join('/')}`;
}

/** Megabits per second (decimal): bytes * 8 / durationMs / 1000, as in production. */
export function calculateMbps(bytes: number, durationMs: number): number {
  if (bytes < 0) {
    throw new Error('bytes must not be negative');
  }
  if (durationMs <= 0) {
    throw new Error('duration must be positive');
  }
  return (bytes * 8) / durationMs / 1_000;
}

async function download(
  endpoint: string,
  bytes: number,
  signal?: AbortSignal,
): Promise<SpeedTestResult> {
  const separator = endpoint.includes('?') ? '&' : '?';
  const cacheBust = `${Date.now()}${Math.floor(Math.random() * 1_000_000)}`;
  const url = `${endpoint}${separator}bytes=${bytes}&cacheBust=${cacheBust}`;

  // Bounded by a timeout; an optional caller signal (e.g. the screen unmounting) also aborts the
  // request so a navigated-away speed test stops downloading instead of running to completion.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  const onCallerAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) {
      controller.abort();
    } else {
      signal.addEventListener('abort', onCallerAbort);
    }
  }
  try {
    const startedMs = Date.now();
    const response = await fetch(url, {
      method: 'GET',
      headers: { 'Accept-Encoding': 'identity' },
      signal: controller.signal,
    });
    // Headers have arrived — the closest RN analogue to time-to-first-byte (see file comment).
    const headersMs = Date.now();
    if (response.status < 200 || response.status > 299) {
      throw new Error(`speed test HTTP ${response.status}`);
    }
    const buffer = await response.arrayBuffer();
    const finishedMs = Date.now();

    const downloaded = buffer.byteLength;
    if (downloaded <= 0) {
      throw new Error('speed test returned no data');
    }
    const durationMs = Math.max(finishedMs - startedMs, 1);
    return {
      bytesDownloaded: downloaded,
      durationMs,
      timeToFirstByteMs: headersMs - startedMs,
      downloadMbps: calculateMbps(downloaded, durationMs),
    };
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onCallerAbort);
  }
}

/**
 * Runs the production two-phase test against `{broker}/api/v1/speed-test`: a 1 MB warmup download
 * followed by the measured 10 MB download; the second download's result is returned. An optional
 * `signal` aborts an in-flight run (e.g. when the Settings screen unmounts).
 */
export async function runSpeedTest(
  brokerUrl: string,
  warmupBytes: number = DEFAULT_WARMUP_BYTES,
  measurementBytes: number = DEFAULT_MEASUREMENT_BYTES,
  signal?: AbortSignal,
): Promise<SpeedTestResult> {
  const endpoint = speedTestUrl(brokerUrl);
  await download(endpoint, warmupBytes, signal);
  return download(endpoint, measurementBytes, signal);
}
