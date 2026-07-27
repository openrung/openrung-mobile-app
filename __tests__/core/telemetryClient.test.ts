const mockSendTelemetryBatchJSON = jest.fn();

jest.mock('../../src/native/OpenRungBroker', () => ({
  sendTelemetryBatchJSON: (...args: unknown[]) =>
    mockSendTelemetryBatchJSON(...args),
}));

import {
  sendTelemetry,
  type TelemetryEvent,
} from '../../src/net/telemetryClient';

const EVENT: TelemetryEvent = {
  schema_version: 1,
  event_id: 'event-1',
  event: 'speed_test_completed',
  occurred_at: '2026-07-26T12:34:56.000Z',
  client_id: 'client-a',
  session_id: 'session-a',
  attributes: {
    provider: 'openrung_broker',
    test_type: 'manual_download',
  },
  measurements: {
    bytes_downloaded: 10_000_000,
    download_duration_ms: 1_025,
    time_to_first_byte_ms: 75,
    download_mbps_milli: 78_048,
  },
};

beforeEach(() => {
  mockSendTelemetryBatchJSON.mockReset();
  mockSendTelemetryBatchJSON.mockResolvedValue(undefined);
});

describe('sendTelemetry', () => {
  it('serializes the existing events envelope exactly and forwards cancellation', async () => {
    const signal = new AbortController().signal;

    await sendTelemetry('https://broker.openrung.org/', [EVENT], signal);

    expect(mockSendTelemetryBatchJSON).toHaveBeenCalledWith(
      {
        brokerUrl: 'https://broker.openrung.org/',
        batchJson: JSON.stringify({ events: [EVENT] }),
      },
      signal,
    );
  });

  it('keeps an empty batch as a transport-free no-op', async () => {
    await expect(
      sendTelemetry('https://broker.openrung.org/', []),
    ).resolves.toBeUndefined();
    expect(mockSendTelemetryBatchJSON).not.toHaveBeenCalled();
  });

  it('propagates structured native failure without a JavaScript network fallback', async () => {
    const failure = Object.assign(new Error('rate limited'), {
      kind: 'rate_limited',
      httpStatus: 429,
      retryAfterMillis: 5_000,
    });
    mockSendTelemetryBatchJSON.mockRejectedValue(failure);
    const fetchSpy = jest
      .spyOn(globalThis, 'fetch')
      .mockRejectedValue(new Error('fetch must not be used'));

    await expect(
      sendTelemetry('https://broker.openrung.org/', [EVENT]),
    ).rejects.toBe(failure);
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });
});
