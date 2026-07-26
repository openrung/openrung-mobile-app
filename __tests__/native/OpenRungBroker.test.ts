import { NativeModules } from 'react-native';

import {
  OpenRungBrokerError,
  createBrokerRequestId,
  fetchManifestCandidate,
  firstReachable,
  runSpeedTest,
  sendTelemetryBatchJSON,
  toOpenRungBrokerError,
} from '../../src/native/OpenRungBroker';

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
};

interface NativeBrokerMock {
  firstReachable: jest.Mock;
  runSpeedTest: jest.Mock;
  sendTelemetryBatchJSON: jest.Mock;
  fetchManifestCandidate: jest.Mock;
  cancel: jest.Mock;
}

const nativeModules = NativeModules as Record<string, unknown>;
const hadOriginalModule = Object.prototype.hasOwnProperty.call(
  nativeModules,
  'OpenRungBroker',
);
const originalModule = nativeModules.OpenRungBroker;

const RELAY_RESULT = {
  brokerUrl: 'https://winner.example/',
  relayJson: '{"count":0,"server_time":"2026-07-26T00:00:00Z","relays":[]}',
  keyId: 'key-1',
  signatureVerified: true,
};

const SPEED_RESULT = {
  bytes: 10_000_000,
  ttfbMillis: 81,
  downloadDurationMillis: 920,
  totalDurationMillis: 1_037,
  mbps: 77.145612,
};

const MANIFEST_RESULT = {
  bodyJson: '{"schema":1,"payload_b64":"e30="}',
  sourceUrl: 'https://broker.openrung.org/api/v1/app-manifest',
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function nativeMock(): NativeBrokerMock {
  return {
    firstReachable: jest.fn(async () => RELAY_RESULT),
    runSpeedTest: jest.fn(async () => SPEED_RESULT),
    sendTelemetryBatchJSON: jest.fn(async () => ({})),
    fetchManifestCandidate: jest.fn(async () => MANIFEST_RESULT),
    cancel: jest.fn(async () => true),
  };
}

function installNative(module: NativeBrokerMock | Record<string, unknown>): void {
  nativeModules.OpenRungBroker = module;
}

async function capturedError(promise: Promise<unknown>): Promise<OpenRungBrokerError> {
  try {
    await promise;
    throw new Error('expected promise to reject');
  } catch (error) {
    expect(error).toBeInstanceOf(OpenRungBrokerError);
    return error as OpenRungBrokerError;
  }
}

beforeEach(() => {
  installNative(nativeMock());
});

afterAll(() => {
  if (hadOriginalModule) {
    nativeModules.OpenRungBroker = originalModule;
  } else {
    delete nativeModules.OpenRungBroker;
  }
});

describe('OpenRungBroker native result mapping', () => {
  it('forwards each classic-module call and returns plain typed snapshots', async () => {
    const module = nativeMock();
    installNative(module);

    await expect(
      firstReachable({
        primary: 'https://primary.example/',
        limit: 20,
        clientId: 'client-a',
        sessionId: 'session-a',
      }),
    ).resolves.toEqual(RELAY_RESULT);
    await expect(runSpeedTest({ brokerUrl: 'https://speed.example/' })).resolves.toEqual(
      SPEED_RESULT,
    );
    await expect(
      fetchManifestCandidate({
        candidateUrl: 'https://broker.openrung.org/api/v1/app-manifest',
      }),
    ).resolves.toEqual(MANIFEST_RESULT);
    await expect(
      sendTelemetryBatchJSON({
        brokerUrl: 'https://telemetry.example/',
        batchJson: '{"events":[]}',
      }),
    ).resolves.toBeUndefined();

    const requestIds = [
      module.firstReachable.mock.calls[0][0],
      module.runSpeedTest.mock.calls[0][0],
      module.fetchManifestCandidate.mock.calls[0][0],
      module.sendTelemetryBatchJSON.mock.calls[0][0],
    ];
    expect(new Set(requestIds).size).toBe(4);
    expect(module.firstReachable).toHaveBeenCalledWith(
      requestIds[0],
      'https://primary.example/',
      20,
      'client-a',
      'session-a',
    );
    expect(module.runSpeedTest).toHaveBeenCalledWith(
      requestIds[1],
      'https://speed.example/',
    );
    expect(module.fetchManifestCandidate).toHaveBeenCalledWith(
      requestIds[2],
      'https://broker.openrung.org/api/v1/app-manifest',
    );
    expect(module.sendTelemetryBatchJSON).toHaveBeenCalledWith(
      requestIds[3],
      'https://telemetry.example/',
      '{"events":[]}',
    );
  });

  it.each([
    [null],
    [{ ...RELAY_RESULT, brokerUrl: 42 }],
    [{ ...RELAY_RESULT, signatureVerified: 'yes' }],
  ])('maps malformed native relay snapshots to decode (%p)', async value => {
    const module = nativeMock();
    module.firstReachable.mockResolvedValue(value);
    installNative(module);

    const error = await capturedError(
      firstReachable({
        primary: '',
        limit: 5,
        clientId: '',
        sessionId: '',
      }),
    );
    expect(error.kind).toBe('decode');
  });

  it('maps malformed speed and manifest snapshots to decode', async () => {
    const module = nativeMock();
    module.runSpeedTest.mockResolvedValue({ ...SPEED_RESULT, mbps: Number.NaN });
    module.fetchManifestCandidate.mockResolvedValue({ bodyJson: '{}', sourceUrl: null });
    installNative(module);

    expect((await capturedError(runSpeedTest({ brokerUrl: 'https://speed/' }))).kind).toBe(
      'decode',
    );
    expect(
      (
        await capturedError(
          fetchManifestCandidate({
            candidateUrl: 'https://broker.openrung.org/api/v1/app-manifest',
          }),
        )
      ).kind,
    ).toBe('decode');
  });
});

describe('OpenRungBroker structured errors and availability', () => {
  it.each([
    'cancelled',
    'timeout',
    'rate_limited',
    'http_status',
    'dns',
    'tls',
    'network',
    'verification',
    'validation',
    'unknown',
    'unavailable',
    'decode',
  ] as const)('preserves the structured %s failure kind', kind => {
    expect(
      toOpenRungBrokerError({
        code: 'E_NATIVE',
        message: 'bounded diagnostic',
        userInfo: { kind },
      }),
    ).toMatchObject({ kind, message: 'bounded diagnostic' });
  });

  it('preserves kind, HTTP status, retry-after, and a sanitized message', async () => {
    const module = nativeMock();
    module.firstReachable.mockRejectedValue(
      Object.assign(new Error('  retry\nlater\tplease  '), {
        code: 'rate_limited',
        userInfo: {
          kind: 'rate_limited',
          httpStatus: 429,
          retryAfterMillis: 12_345,
        },
      }),
    );
    installNative(module);

    const error = await capturedError(
      firstReachable({
        primary: '',
        limit: 5,
        clientId: '',
        sessionId: '',
      }),
    );
    expect(error).toMatchObject({
      name: 'OpenRungBrokerError',
      kind: 'rate_limited',
      httpStatus: 429,
      retryAfterMillis: 12_345,
      message: 'retry later please',
    });
  });

  it('accepts platform field aliases but never parses diagnostics for policy', () => {
    expect(
      toOpenRungBrokerError({
        code: 'http_status',
        message: 'HTTP 503',
        httpStatus: 503,
        retryAfterMilliseconds: 8_000,
      }),
    ).toMatchObject({
      kind: 'http_status',
      httpStatus: 503,
      retryAfterMillis: 8_000,
    });
    expect(toOpenRungBrokerError(new Error('timeout in prose')).kind).toBe('unknown');
  });

  it('rejects a missing module as unavailable and requests a native rebuild', async () => {
    delete nativeModules.OpenRungBroker;

    const error = await capturedError(runSpeedTest({ brokerUrl: 'https://broker/' }));
    expect(error.kind).toBe('unavailable');
    expect(error.message).toMatch(/rebuild the native app/i);
  });

  it('rejects a stale module missing any required method as unavailable', async () => {
    const stale = nativeMock() as unknown as Record<string, unknown>;
    delete stale.fetchManifestCandidate;
    installNative(stale);

    const error = await capturedError(
      fetchManifestCandidate({
        candidateUrl: 'https://broker.openrung.org/api/v1/app-manifest',
      }),
    );
    expect(error.kind).toBe('unavailable');
  });
});

describe('OpenRungBroker request IDs and AbortSignal behavior', () => {
  it('generates unique IDs even when clock and randomness are fixed', () => {
    const now = jest.spyOn(Date, 'now').mockReturnValue(1_800_000_000_000);
    const random = jest.spyOn(Math, 'random').mockReturnValue(0.25);
    try {
      const ids = Array.from({ length: 200 }, () => createBrokerRequestId());
      expect(new Set(ids).size).toBe(ids.length);
    } finally {
      now.mockRestore();
      random.mockRestore();
    }
  });

  it('does not start or cancel native work for an already-aborted signal', async () => {
    const module = nativeMock();
    installNative(module);
    const controller = new AbortController();
    controller.abort();

    const error = await capturedError(
      runSpeedTest({ brokerUrl: 'https://broker/' }, controller.signal),
    );
    expect(error.kind).toBe('cancelled');
    expect(module.runSpeedTest).not.toHaveBeenCalled();
    expect(module.cancel).not.toHaveBeenCalled();
  });

  it('cancels an in-flight request by its exact ID and suppresses late success', async () => {
    const module = nativeMock();
    const pending = deferred<typeof SPEED_RESULT>();
    module.runSpeedTest.mockReturnValue(pending.promise);
    installNative(module);
    const controller = new AbortController();
    const remove = jest.spyOn(controller.signal, 'removeEventListener');

    const outcome = runSpeedTest({ brokerUrl: 'https://broker/' }, controller.signal);
    const requestId = module.runSpeedTest.mock.calls[0][0];
    controller.abort();

    const error = await capturedError(outcome);
    expect(error.kind).toBe('cancelled');
    expect(module.cancel).toHaveBeenCalledTimes(1);
    expect(module.cancel).toHaveBeenCalledWith(requestId);
    expect(remove).toHaveBeenCalledWith('abort', expect.any(Function));

    // The native completion can still race back across the bridge, but it cannot settle twice.
    pending.resolve(SPEED_RESULT);
    await Promise.resolve();
    remove.mockRestore();
  });

  it('lets cancellation win when native success is queued in the same turn', async () => {
    const module = nativeMock();
    const pending = deferred<typeof SPEED_RESULT>();
    module.runSpeedTest.mockReturnValue(pending.promise);
    installNative(module);
    const controller = new AbortController();

    const outcome = runSpeedTest({ brokerUrl: 'https://broker/' }, controller.signal);
    pending.resolve(SPEED_RESULT);
    controller.abort();

    expect((await capturedError(outcome)).kind).toBe('cancelled');
    expect(module.cancel).toHaveBeenCalledTimes(1);
  });

  it('still rejects as cancelled when a stale native cancel method throws synchronously', async () => {
    const module = nativeMock();
    module.runSpeedTest.mockReturnValue(deferred<typeof SPEED_RESULT>().promise);
    module.cancel.mockImplementation(() => {
      throw new Error('stale native bridge');
    });
    installNative(module);
    const controller = new AbortController();

    const outcome = runSpeedTest({ brokerUrl: 'https://broker/' }, controller.signal);
    controller.abort();

    expect((await capturedError(outcome)).kind).toBe('cancelled');
    expect(module.cancel).toHaveBeenCalledTimes(1);
  });

  it('does not cancel after a completed request and removes the abort listener', async () => {
    const module = nativeMock();
    installNative(module);
    const controller = new AbortController();
    const remove = jest.spyOn(controller.signal, 'removeEventListener');

    await expect(
      runSpeedTest({ brokerUrl: 'https://broker/' }, controller.signal),
    ).resolves.toEqual(SPEED_RESULT);
    expect(remove).toHaveBeenCalledWith('abort', expect.any(Function));

    controller.abort();
    expect(module.cancel).not.toHaveBeenCalled();
    remove.mockRestore();
  });

  it('isolates concurrent requests when only one is cancelled', async () => {
    const module = nativeMock();
    const firstPending = deferred<typeof SPEED_RESULT>();
    const secondPending = deferred<typeof SPEED_RESULT>();
    module.runSpeedTest
      .mockReturnValueOnce(firstPending.promise)
      .mockReturnValueOnce(secondPending.promise);
    installNative(module);
    const firstController = new AbortController();
    const secondController = new AbortController();

    const first = runSpeedTest({ brokerUrl: 'https://one/' }, firstController.signal);
    const second = runSpeedTest({ brokerUrl: 'https://two/' }, secondController.signal);
    const firstId = module.runSpeedTest.mock.calls[0][0];
    const secondId = module.runSpeedTest.mock.calls[1][0];
    expect(firstId).not.toBe(secondId);

    firstController.abort();
    secondPending.resolve({ ...SPEED_RESULT, bytes: 22 });

    expect((await capturedError(first)).kind).toBe('cancelled');
    await expect(second).resolves.toMatchObject({ bytes: 22 });
    expect(module.cancel).toHaveBeenCalledTimes(1);
    expect(module.cancel).toHaveBeenCalledWith(firstId);

    firstPending.reject(new Error('cancelled natively'));
    await Promise.resolve();
  });
});
