import type { NativeIdentity } from '../native/types';
import { sendTelemetryBatchJSON } from '../native/OpenRungBroker';
import type { SpeedTestResult } from './speedTestClient';

/**
 * Telemetry client, ported from the production `telemetry/TelemetryClient.kt` /
 * `telemetry/TelemetryEvent.kt`. The TS side only ever emits the speed-test events
 * (`speed_test_completed` / `speed_test_failed`); the native connect path keeps the full
 * production telemetry (contract §8).
 */

export interface TelemetryEvent {
  schema_version: number; // always 1
  event_id: string; // UUID
  event: string;
  occurred_at: string; // ISO instant
  client_id: string;
  session_id: string;
  relay_id?: string;
  application_package?: string;
  application_uid?: number;
  // destination_ip/destination_port/protocol were removed from the schema on purpose: the
  // broker discards them, and they are a privacy hazard. Do not reintroduce them.
  attributes: Record<string, string>;
  measurements: Record<string, number>;
}

export interface TelemetryBatch {
  events: TelemetryEvent[];
}

/** Tiny local RFC-4122 v4 UUID helper (no crypto dependency needed for a pseudonymous id). */
export function uuid4(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, char => {
    const random = (Math.random() * 16) | 0;
    const value = char === 'x' ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}

/**
 * Serializes the existing speed-test telemetry envelope and hands it to brokerapi. An empty list
 * remains a no-op, and general VPN telemetry remains native-owned.
 */
export async function sendTelemetry(
  baseUrl: string,
  events: TelemetryEvent[],
  signal?: AbortSignal,
): Promise<void> {
  if (events.length === 0) {
    return;
  }
  const batch: TelemetryBatch = { events };
  await sendTelemetryBatchJSON(
    {
      brokerUrl: baseUrl,
      batchJson: JSON.stringify(batch),
    },
    signal,
  );
}

interface ActiveIdentity {
  clientId: string;
  sessionId: string;
}

function requireSession(identity: NativeIdentity): ActiveIdentity {
  if (identity.sessionId === null) {
    // Callers must skip telemetry when no session is active (contract §4).
    throw new Error('no active telemetry session');
  }
  return { clientId: identity.clientId, sessionId: identity.sessionId };
}

/**
 * Existing `speed_test_completed` schema with the production attributes and measurements
 * (Mbps stored as milli-Mbps in a whole number).
 */
export function buildSpeedTestCompletedEvent(
  identity: NativeIdentity,
  result: SpeedTestResult,
): TelemetryEvent {
  const active = requireSession(identity);
  return {
    schema_version: 1,
    event_id: uuid4(),
    event: 'speed_test_completed',
    occurred_at: new Date().toISOString(),
    client_id: active.clientId,
    session_id: active.sessionId,
    attributes: {
      provider: 'openrung_broker',
      test_type: 'manual_download',
    },
    measurements: {
      bytes_downloaded: Math.trunc(result.bytesDownloaded),
      download_duration_ms: Math.trunc(result.durationMs),
      time_to_first_byte_ms: Math.trunc(result.timeToFirstByteMs),
      download_mbps_milli: Math.trunc(result.downloadMbps * 1_000),
    },
  };
}

/**
 * The `speed_test_failed` event, built exactly like the production Settings screen does
 * (attributes `provider` + `error_type`, no measurements).
 */
export function buildSpeedTestFailedEvent(
  identity: NativeIdentity,
  errorType: string,
): TelemetryEvent {
  const active = requireSession(identity);
  return {
    schema_version: 1,
    event_id: uuid4(),
    event: 'speed_test_failed',
    occurred_at: new Date().toISOString(),
    client_id: active.clientId,
    session_id: active.sessionId,
    attributes: {
      provider: 'openrung_broker',
      error_type: errorType,
    },
    measurements: {},
  };
}
