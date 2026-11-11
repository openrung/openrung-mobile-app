import { formatUptime } from '../../src/components/SessionTimer';

describe('formatUptime', () => {
  it('renders zero-padded hh:mm:ss', () => {
    expect(formatUptime(0)).toBe('00:00:00');
    expect(formatUptime(65_000)).toBe('00:01:05');
    expect(formatUptime(3_661_000)).toBe('01:01:01');
  });

  it('clamps negative elapsed (clock skew) to zero', () => {
    expect(formatUptime(-5_000)).toBe('00:00:00');
  });

  it('pins at 99:59:59 without widening the column', () => {
    expect(formatUptime(99 * 3_600_000)).toBe('99:00:00');
    expect(formatUptime(500 * 3_600_000)).toBe('99:59:59');
  });
});
