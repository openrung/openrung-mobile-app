/**
 * Human-readable traffic formatting for the live stats row. Rates arrive from
 * native as bytes/second (contract §3 TrafficStats) and are displayed in bits
 * per second (the convention users know from speed tests); totals stay in
 * bytes. Decimal units (1000), matching the speed test's Mbps math.
 */

/** bytes/sec -> "3.2 Mbps" / "480 Kbps" / "1.1 Gbps". */
export function formatBitrate(bytesPerSecond: number): string {
  const bitsPerSecond = Math.max(0, bytesPerSecond) * 8;
  if (bitsPerSecond >= 1_000_000_000) {
    return `${(bitsPerSecond / 1_000_000_000).toFixed(1)} Gbps`;
  }
  if (bitsPerSecond >= 1_000_000) {
    return `${(bitsPerSecond / 1_000_000).toFixed(1)} Mbps`;
  }
  if (bitsPerSecond >= 1_000) {
    return `${Math.round(bitsPerSecond / 1_000)} Kbps`;
  }
  return `${Math.round(bitsPerSecond)} bps`;
}

/** bytes -> "128 MB" / "1.2 GB" / "480 KB". */
export function formatBytes(totalBytes: number): string {
  const bytes = Math.max(0, totalBytes);
  if (bytes >= 1_000_000_000) {
    return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
  }
  if (bytes >= 1_000_000) {
    return `${Math.round(bytes / 1_000_000)} MB`;
  }
  if (bytes >= 1_000) {
    return `${Math.round(bytes / 1_000)} KB`;
  }
  return `${Math.round(bytes)} B`;
}
