import { NativeModules } from 'react-native';

export type BrokerFailureKind =
  | 'cancelled'
  | 'timeout'
  | 'rate_limited'
  | 'http_status'
  | 'dns'
  | 'tls'
  | 'network'
  | 'verification'
  | 'validation'
  | 'unknown'
  | 'unavailable'
  | 'decode';

const FAILURE_KINDS = new Set<BrokerFailureKind>([
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
]);

export class OpenRungBrokerError extends Error {
  readonly kind: BrokerFailureKind;
  readonly httpStatus?: number;
  readonly retryAfterMillis?: number;

  constructor(
    kind: BrokerFailureKind,
    message: string,
    options: { httpStatus?: number; retryAfterMillis?: number } = {},
  ) {
    super(sanitizeMessage(message) || `Native broker request failed (${kind}).`);
    this.name = 'OpenRungBrokerError';
    this.kind = kind;
    this.httpStatus = positiveFiniteNumber(options.httpStatus);
    this.retryAfterMillis = positiveFiniteNumber(options.retryAfterMillis);
  }
}

export interface FirstReachableRequest {
  primary: string;
  limit: number;
  clientId: string;
  sessionId: string;
}

export interface FirstReachableResult {
  brokerUrl: string;
  relayJson: string;
  keyId: string;
  signatureVerified: boolean;
}

export interface RunSpeedTestRequest {
  brokerUrl: string;
}

export interface RunSpeedTestResult {
  bytes: number;
  ttfbMillis: number;
  downloadDurationMillis: number;
  totalDurationMillis: number;
  mbps: number;
}

export interface SendTelemetryBatchJSONRequest {
  brokerUrl: string;
  batchJson: string;
}

export interface FetchManifestCandidateRequest {
  candidateUrl: string;
}

export interface FetchManifestCandidateResult {
  bodyJson: string;
  sourceUrl: string;
}

interface NativeBrokerModule {
  firstReachable(
    requestId: string,
    primary: string,
    limit: number,
    clientId: string,
    sessionId: string,
  ): Promise<unknown>;
  runSpeedTest(requestId: string, brokerUrl: string): Promise<unknown>;
  sendTelemetryBatchJSON(
    requestId: string,
    brokerUrl: string,
    batchJson: string,
  ): Promise<unknown>;
  fetchManifestCandidate(requestId: string, candidateUrl: string): Promise<unknown>;
  cancel(requestId: string): Promise<boolean>;
}

let requestSequence = 0;

/** Process-unique IDs make concurrent native requests independently cancellable. */
export function createBrokerRequestId(): string {
  requestSequence = (requestSequence + 1) % Number.MAX_SAFE_INTEGER;
  return `rn-${Date.now().toString(36)}-${requestSequence.toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

export function toOpenRungBrokerError(error: unknown): OpenRungBrokerError {
  if (error instanceof OpenRungBrokerError) {
    return error;
  }
  const record = objectRecord(error);
  const userInfo = objectRecord(record?.userInfo);
  const candidateKind = stringValue(userInfo?.kind) ?? stringValue(record?.kind);
  const code = stringValue(record?.code);
  const kind = FAILURE_KINDS.has(candidateKind as BrokerFailureKind)
    ? (candidateKind as BrokerFailureKind)
    : FAILURE_KINDS.has(code as BrokerFailureKind)
      ? (code as BrokerFailureKind)
      : 'unknown';
  const message =
    stringValue(record?.message) ??
    stringValue(userInfo?.message) ??
    (typeof error === 'string' ? error : '');
  return new OpenRungBrokerError(kind, message, {
    httpStatus:
      numberValue(userInfo?.httpStatus) ??
      numberValue(record?.httpStatus) ??
      numberValue(userInfo?.status),
    retryAfterMillis:
      numberValue(userInfo?.retryAfterMillis) ??
      numberValue(record?.retryAfterMillis) ??
      numberValue(userInfo?.retryAfterMilliseconds) ??
      numberValue(record?.retryAfterMilliseconds),
  });
}

export function firstReachable(
  request: FirstReachableRequest,
  signal?: AbortSignal,
): Promise<FirstReachableResult> {
  return runRequest(
    (module, requestId) =>
      module.firstReachable(
        requestId,
        request.primary,
        request.limit,
        request.clientId,
        request.sessionId,
      ),
    decodeFirstReachable,
    signal,
  );
}

export function runSpeedTest(
  request: RunSpeedTestRequest,
  signal?: AbortSignal,
): Promise<RunSpeedTestResult> {
  return runRequest(
    (module, requestId) => module.runSpeedTest(requestId, request.brokerUrl),
    decodeSpeedTest,
    signal,
  );
}

export function sendTelemetryBatchJSON(
  request: SendTelemetryBatchJSONRequest,
  signal?: AbortSignal,
): Promise<void> {
  return runRequest(
    (module, requestId) =>
      module.sendTelemetryBatchJSON(requestId, request.brokerUrl, request.batchJson),
    () => undefined,
    signal,
  );
}

export function fetchManifestCandidate(
  request: FetchManifestCandidateRequest,
  signal?: AbortSignal,
): Promise<FetchManifestCandidateResult> {
  return runRequest(
    (module, requestId) => module.fetchManifestCandidate(requestId, request.candidateUrl),
    decodeManifestCandidate,
    signal,
  );
}

function runRequest<Result>(
  invoke: (module: NativeBrokerModule, requestId: string) => Promise<unknown>,
  decode: (value: unknown) => Result,
  signal?: AbortSignal,
): Promise<Result> {
  if (signal?.aborted) {
    return Promise.reject(cancelledError());
  }

  let module: NativeBrokerModule;
  try {
    module = requireNativeModule();
  } catch (error) {
    return Promise.reject(toOpenRungBrokerError(error));
  }

  const requestId = createBrokerRequestId();
  return new Promise<Result>((resolve, reject) => {
    let settled = false;
    let nativeStarted = false;

    const cleanup = () => signal?.removeEventListener('abort', onAbort);
    const settle = (action: () => void): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      action();
    };
    const onAbort = (): void => {
      settle(() => {
        if (nativeStarted) {
          // Cancellation is best-effort from JS's perspective: the caller is already aborted,
          // while the platform registry and PR 2 runner own definitive operation cleanup.
          try {
            Promise.resolve(module.cancel(requestId)).catch(() => undefined);
          } catch {
            // A stale bridge can throw synchronously instead of returning a rejected Promise.
            // Abort still owns the public outcome and must not leave the request unsettled.
          }
        }
        reject(cancelledError());
      });
    };

    signal?.addEventListener('abort', onAbort);
    // Covers an abort landing between the pre-check and listener registration.
    if (signal?.aborted) {
      onAbort();
      return;
    }

    let nativePromise: Promise<unknown>;
    try {
      nativeStarted = true;
      nativePromise = invoke(module, requestId);
    } catch (error) {
      settle(() => reject(toOpenRungBrokerError(error)));
      return;
    }

    Promise.resolve(nativePromise).then(
      value => {
        settle(() => {
          try {
            resolve(decode(value));
          } catch (error) {
            reject(toOpenRungBrokerError(error));
          }
        });
      },
      error => settle(() => reject(toOpenRungBrokerError(error))),
    );
  });
}

function requireNativeModule(): NativeBrokerModule {
  const module = (NativeModules as Record<string, unknown>).OpenRungBroker;
  if (typeof module !== 'object' || module === null) {
    throw unavailableError();
  }
  const record = module as Record<string, unknown>;
  const methods: (keyof NativeBrokerModule)[] = [
    'firstReachable',
    'runSpeedTest',
    'sendTelemetryBatchJSON',
    'fetchManifestCandidate',
    'cancel',
  ];
  if (methods.some(method => typeof record[method] !== 'function')) {
    throw unavailableError();
  }
  return module as NativeBrokerModule;
}

function decodeFirstReachable(value: unknown): FirstReachableResult {
  const record = requiredRecord(value);
  return {
    brokerUrl: requiredString(record.brokerUrl),
    relayJson: requiredString(record.relayJson),
    keyId: requiredString(record.keyId),
    signatureVerified: requiredBoolean(record.signatureVerified),
  };
}

function decodeSpeedTest(value: unknown): RunSpeedTestResult {
  const record = requiredRecord(value);
  return {
    bytes: requiredNumber(record.bytes),
    ttfbMillis: requiredNumber(record.ttfbMillis),
    downloadDurationMillis: requiredNumber(record.downloadDurationMillis),
    totalDurationMillis: requiredNumber(record.totalDurationMillis),
    mbps: requiredNumber(record.mbps),
  };
}

function decodeManifestCandidate(value: unknown): FetchManifestCandidateResult {
  const record = requiredRecord(value);
  return {
    bodyJson: requiredString(record.bodyJson),
    sourceUrl: requiredString(record.sourceUrl),
  };
}

function requiredRecord(value: unknown): Record<string, unknown> {
  const record = objectRecord(value);
  if (record === null) {
    throw decodeError();
  }
  return record;
}

function requiredString(value: unknown): string {
  if (typeof value !== 'string') {
    throw decodeError();
  }
  return value;
}

function requiredBoolean(value: unknown): boolean {
  if (typeof value !== 'boolean') {
    throw decodeError();
  }
  return value;
}

function requiredNumber(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw decodeError();
  }
  return value;
}

function objectRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)
    : null;
}

function stringValue(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function positiveFiniteNumber(value: unknown): number | undefined {
  const number = numberValue(value);
  return number !== undefined && number > 0 ? number : undefined;
}

function sanitizeMessage(value: string): string {
  const sanitized = value
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  let bytes = 0;
  let bounded = '';
  for (const character of sanitized) {
    const codePoint = character.codePointAt(0) ?? 0;
    const width =
      codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
    if (bytes + width > 256) {
      break;
    }
    bytes += width;
    bounded += character;
  }
  return bounded;
}

function cancelledError(): OpenRungBrokerError {
  return new OpenRungBrokerError('cancelled', 'Native broker request was cancelled.');
}

function unavailableError(): OpenRungBrokerError {
  return new OpenRungBrokerError(
    'unavailable',
    'The OpenRungBroker native module is unavailable. Rebuild the native app to install the broker transport.',
  );
}

function decodeError(): OpenRungBrokerError {
  return new OpenRungBrokerError('decode', 'The native broker response could not be decoded.');
}
