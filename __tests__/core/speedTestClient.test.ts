import {
  calculateMbps,
  runUploadTest,
  speedTestUrl,
} from '../../src/net/speedTestClient';

describe('calculateMbps', () => {
  it('computes decimal megabits per second', () => {
    // 10 MB in 1000 ms = 80 Mbps.
    expect(calculateMbps(10_000_000, 1_000)).toBeCloseTo(80, 5);
  });

  it('rejects negative bytes and non-positive durations', () => {
    expect(() => calculateMbps(-1, 100)).toThrow(/negative/);
    expect(() => calculateMbps(100, 0)).toThrow(/positive/);
  });
});

describe('speedTestUrl', () => {
  it('joins the api path onto the broker base', () => {
    expect(speedTestUrl('http://54.238.185.205:8080/')).toBe(
      'http://54.238.185.205:8080/api/v1/speed-test',
    );
  });
});

describe('runUploadTest', () => {
  afterEach(() => {
    delete (globalThis as Record<string, unknown>).fetch;
  });

  it('POSTs a warmup then a measured body and reports the measured result', async () => {
    const calls: Array<{ method?: string; bodyLength: number }> = [];
    (globalThis as Record<string, unknown>).fetch = jest.fn(async (_url: string, init: RequestInit) => {
      calls.push({
        method: init.method,
        bodyLength: typeof init.body === 'string' ? init.body.length : 0,
      });
      return { status: 200 } as Response;
    });

    const result = await runUploadTest('https://sink.example/__up', 1_000, 10_000);

    expect(calls).toHaveLength(2); // warmup + measurement
    expect(calls[0]).toMatchObject({ method: 'POST', bodyLength: 1_000 });
    expect(calls[1]).toMatchObject({ method: 'POST', bodyLength: 10_000 });
    expect(result.bytesUploaded).toBe(10_000);
    expect(result.uploadMbps).toBeGreaterThan(0);
  });

  it('throws on a non-2xx response', async () => {
    (globalThis as Record<string, unknown>).fetch = jest.fn(async () => ({ status: 500 }) as Response);
    await expect(runUploadTest('https://sink.example/__up', 1_000, 10_000)).rejects.toThrow(/HTTP 500/);
  });
});
