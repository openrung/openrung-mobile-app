const mockNativeRunSpeedTest = jest.fn();

jest.mock('../../src/native/OpenRungBroker', () => ({
  runSpeedTest: (...args: unknown[]) => mockNativeRunSpeedTest(...args),
}));

import { runSpeedTest } from '../../src/net/speedTestClient';

beforeEach(() => {
  mockNativeRunSpeedTest.mockReset();
});

describe('runSpeedTest', () => {
  it('maps the complete native measurement into the existing Settings model', async () => {
    const signal = new AbortController().signal;
    mockNativeRunSpeedTest.mockResolvedValue({
      bytes: 10_000_000,
      ttfbMillis: 75,
      downloadDurationMillis: 901,
      totalDurationMillis: 1_025,
      mbps: 78.04878,
    });

    await expect(
      runSpeedTest('https://broker.openrung.org/', signal),
    ).resolves.toEqual({
      bytesDownloaded: 10_000_000,
      durationMs: 1_025,
      timeToFirstByteMs: 75,
      downloadMbps: 78.04878,
    });
    expect(mockNativeRunSpeedTest).toHaveBeenCalledWith(
      { brokerUrl: 'https://broker.openrung.org/' },
      signal,
    );
  });

  it('propagates native cancellation and never invokes JavaScript fetch', async () => {
    const failure = Object.assign(new Error('cancelled'), { kind: 'cancelled' });
    mockNativeRunSpeedTest.mockRejectedValue(failure);
    const fetchSpy = jest
      .spyOn(globalThis, 'fetch')
      .mockRejectedValue(new Error('fetch must not be used'));

    await expect(runSpeedTest('https://broker.openrung.org/')).rejects.toBe(failure);
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });
});
