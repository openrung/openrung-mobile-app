import { sendTelemetryBatchJSON } from '../native/OpenRungBroker';

/**
 * Telemetry client, ported from the production `telemetry/TelemetryClient.kt` /
 * `telemetry/TelemetryEvent.kt`. The TS side currently builds no events of its own; the
 * native connect path keeps the full production telemetry (contract §8).
 */

export interface TelemetryEvent {
  schema_version: number; // always 1
  event_id: string; // UUID
  event: string;
  occurred_at: string; // ISO instant
  client_id: string;
  session_id: string;
  // destination_ip/destination_port/protocol were removed from the schema on purpose: the
  // broker discards them, and they are a privacy hazard. Do not reintroduce them.
  attributes: Record<string, string>;
  measurements: Record<string, number>;
}

interface TelemetryBatch {
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
 * Serializes the telemetry envelope and hands it to brokerapi. An empty list remains a no-op,
 * and general VPN telemetry remains native-owned.
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
