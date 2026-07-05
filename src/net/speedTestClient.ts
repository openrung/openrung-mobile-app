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

async function download(endpoint: string, bytes: number): Promise<SpeedTestResult> {
  const separator = endpoint.includes('?') ? '&' : '?';
  const cacheBust = `${Date.now()}${Math.floor(Math.random() * 1_000_000)}`;
  const url = `${endpoint}${separator}bytes=${bytes}&cacheBust=${cacheBust}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
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
  }
}

/**
 * Runs the production two-phase test against `{broker}/api/v1/speed-test`: a 1 MB warmup download
 * followed by the measured 10 MB download; the second download's result is returned.
 */
export async function runSpeedTest(
  brokerUrl: string,
  warmupBytes: number = DEFAULT_WARMUP_BYTES,
  measurementBytes: number = DEFAULT_MEASUREMENT_BYTES,
): Promise<SpeedTestResult> {
  const endpoint = speedTestUrl(brokerUrl);
  await download(endpoint, warmupBytes);
  return download(endpoint, measurementBytes);
}

export interface UploadTestResult {
  bytesUploaded: number;
  durationMs: number;
  uploadMbps: number;
}

/**
 * Upload body: a constant-character string, the one body type RN's fetch reliably
 * supports at this size. Request bodies are never transparently compressed, so the
 * repeated character doesn't shrink on the wire; the sink discards it either way.
 */
function uploadBody(bytes: number): string {
  return 'x'.repeat(bytes);
}

async function upload(endpoint: string, bytes: number): Promise<UploadTestResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const startedMs = Date.now();
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream' },
      body: uploadBody(bytes),
      signal: controller.signal,
    });
    const finishedMs = Date.now();
    if (response.status < 200 || response.status > 299) {
      throw new Error(`upload test HTTP ${response.status}`);
    }
    // Same RN limitation as the download side, mirrored: fetch can't observe
    // request-body streaming, so durationMs is the full round trip until response
    // headers — a slight overestimate of pure upload time.
    const durationMs = Math.max(finishedMs - startedMs, 1);
    return {
      bytesUploaded: bytes,
      durationMs,
      uploadMbps: calculateMbps(bytes, durationMs),
    };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Two-phase upload test mirroring `runSpeedTest`: a 1 MB warmup POST followed by the
 * measured 10 MB POST (the second result is returned). Target is an anonymous
 * discard sink (see AppConfig.SPEEDTEST_UPLOAD_URL).
 */
export async function runUploadTest(
  uploadUrl: string,
  warmupBytes: number = DEFAULT_WARMUP_BYTES,
  measurementBytes: number = DEFAULT_MEASUREMENT_BYTES,
): Promise<UploadTestResult> {
  await upload(uploadUrl, warmupBytes);
  return upload(uploadUrl, measurementBytes);
}
