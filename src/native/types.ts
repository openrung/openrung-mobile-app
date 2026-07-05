// src/native/types.ts — the single source of truth for these types
// (contract docs/CONTRACT.md §3; keep in sync with both native bridges).

export type ConnectionStatus =
  | 'disconnected'
  | 'preparing'
  | 'connecting'
  | 'connected'
  | 'disconnecting'
  | 'failed';

export interface RecentNode {
  countryCode: string; // ISO 3166-1 alpha-2, uppercase
  label: string; // "City, Country" or country name
  latitude: number;
  longitude: number;
}

export interface NativeVpnState {
  status: ConnectionStatus;
  relayLabel: string | null; // resolved geo label, never a raw IP
  lastError: string | null;
  logLines: string[]; // "[HH:mm:ss] message", newest last, cap 80
  recents: RecentNode[]; // newest first, deduped by countryCode, cap 8
}

export interface NativeIdentity {
  clientId: string; // stable install UUID (native-persisted)
  sessionId: string | null; // active telemetry session id, null when idle
}

export interface TrafficStats {
  upBps: number; // instantaneous upload, bytes/sec
  downBps: number; // instantaneous download, bytes/sec
  upTotalBytes: number; // cumulative bytes this session
  downTotalBytes: number;
  updatedAtMs: number; // epoch ms of the sample
}

export interface LatencyTarget {
  id: string; // caller-supplied key echoed back in the result
  host: string;
  port: number;
}

export interface LatencyResult {
  id: string;
  latencyMs: number | null; // null when unreachable/timed out
  reachable: boolean;
}

export interface LatencyMeasurement {
  /** True when probes were routed through the active tunnel (iOS while connected)
   *  instead of the direct path — results then measure the through-tunnel RTT. */
  viaTunnel: boolean;
  results: LatencyResult[];
}

/** 'proxyOnly' = only the listed apps use the VPN; 'bypass' = the listed apps skip it. */
export type SplitTunnelMode = 'off' | 'proxyOnly' | 'bypass';

export interface SplitTunnelConfig {
  mode: SplitTunnelMode;
  packages: string[]; // Android package names
}

export interface InstalledApp {
  packageName: string;
  label: string;
  isSystem: boolean;
}

export interface OpenRungVpnModule {
  /** Ask for OS VPN consent (Android: VpnService.prepare dialog; also requests
   *  POST_NOTIFICATIONS on API 33+. iOS: load-or-create the
   *  NETunnelProviderManager and save it). Resolves true when usable. */
  prepare(): Promise<boolean>;
  /** Start (or switch) the tunnel. targetCountry: ISO alpha-2 or null = broker
   *  picks. Resolves once the native start has been dispatched (NOT when
   *  connected — completion is reported via events). */
  connect(brokerUrl: string, targetCountry: string | null): Promise<void>;
  disconnect(): Promise<void>;
  getState(): Promise<NativeVpnState>;
  getIdentity(): Promise<NativeIdentity>;
  /** Latest traffic sample, or null when not connected. Live updates arrive via the
   *  `openrungTrafficChanged` event (~2 s cadence while connected, one zeroed
   *  emission on disconnect). */
  getTrafficStats(): Promise<TrafficStats | null>;
  /** Concurrent TCP-connect timing against relay endpoints (native-capped at 8
   *  sockets in flight). Android probes bypass the active tunnel via a non-VPN
   *  network's socket factory; iOS probes ride the tunnel while connected
   *  (reported via `viaTunnel`). */
  measureLatency(targets: LatencyTarget[], timeoutMs: number): Promise<LatencyMeasurement>;
  /** Apps that can use the network (Android). iOS resolves []. */
  getInstalledApps(): Promise<InstalledApp[]>;
  /** Current split-tunnel config (natively persisted — the VpnService reads it at
   *  establish time). iOS resolves {mode:'off', packages:[]}. */
  getSplitTunnelConfig(): Promise<SplitTunnelConfig>;
  /** Persists the config. needsReconnect is true when it changed while the tunnel
   *  is up — re-calling connect() applies it (clean teardown + re-establish). */
  setSplitTunnelConfig(config: SplitTunnelConfig): Promise<{ needsReconnect: boolean }>;
  /** Full scrubbed runtime log (survives restarts), oldest first, cap ~1000 lines.
   *  The in-memory `logLines` (cap 80) is a live tail; this is the durable record. */
  getPersistedLog(): Promise<string[]>;
  clearPersistedLog(): Promise<void>;
}
