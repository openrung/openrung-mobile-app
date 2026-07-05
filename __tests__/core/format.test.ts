import { formatBitrate, formatBytes } from '../../src/util/format';

describe('formatBitrate (input: bytes/second, output: bits-based rate)', () => {
  it('scales through bps, Kbps, Mbps and Gbps', () => {
    expect(formatBitrate(0)).toBe('0 bps');
    expect(formatBitrate(100)).toBe('800 bps');
    expect(formatBitrate(1_000)).toBe('8 Kbps');
    expect(formatBitrate(400_000)).toBe('3.2 Mbps');
    expect(formatBitrate(150_000_000)).toBe('1.2 Gbps');
  });

  it('clamps negative rates to zero', () => {
    expect(formatBitrate(-5)).toBe('0 bps');
  });
});

describe('formatBytes', () => {
  it('scales through B, KB, MB and GB', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(999)).toBe('999 B');
    expect(formatBytes(128_000)).toBe('128 KB');
    expect(formatBytes(128_000_000)).toBe('128 MB');
    expect(formatBytes(1_200_000_000)).toBe('1.2 GB');
  });
});
