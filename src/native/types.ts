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
}
