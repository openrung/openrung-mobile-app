import { centroid, displayName } from '../model/countryGeo';
import { uuid4 } from '../net/telemetryClient';
import type {
  ConnectionStatus,
  InstalledApp,
  LatencyMeasurement,
  LatencyTarget,
  NativeIdentity,
  NativeVpnState,
  OpenRungVpnModule,
  RecentNode,
  SplitTunnelConfig,
  TrafficStats,
} from './types';

/**
 * Scripted simulator used when the native `OpenRungVpn` module is absent (Jest, fresh Metro
 * without a native rebuild). Walks preparing -> connecting -> connected with fake log lines that
 * mimic the production connect flow, so the UI is fully demoable without native builds
 * (contract §3).
 *
 * Log lines mirror what production `OpenRungStatusStore` records: every status change appends the
 * status label, and the service appends its progress lines in between; timestamps are "[HH:mm:ss]",
 * the log is capped at 80 lines and recents at 8 (newest first, deduped by countryCode).
 */

const MAX_LOG_LINES = 80;
const MAX_RECENTS = 8;
const MAX_PERSISTED_LOG_LINES = 1000;
const TRAFFIC_INTERVAL_MS = 2000;

/**
 * Simplified stand-in for the native scrubber so the Debug screen shows realistic
 * `<ip>`/`<url>` placeholder tokens: production scrubs proxy URIs, URLs, IPs, UUIDs
 * and credential-shaped key=value pairs before a line ever reaches disk.
 */
function mockScrub(message: string): string {
  return message
    .replace(/https?:\/\/[^\s]+/gi, '<url>')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b/g, '<ip>');
}

const MOCK_APPS: InstalledApp[] = [
  { packageName: 'com.android.chrome', label: 'Chrome', isSystem: false },
  { packageName: 'org.mozilla.firefox', label: 'Firefox', isSystem: false },
  { packageName: 'com.whatsapp', label: 'WhatsApp', isSystem: false },
  { packageName: 'org.telegram.messenger', label: 'Telegram', isSystem: false },
  { packageName: 'com.spotify.music', label: 'Spotify', isSystem: false },
  { packageName: 'com.google.android.youtube', label: 'YouTube', isSystem: false },
  { packageName: 'com.android.vending', label: 'Play Store', isSystem: true },
  { packageName: 'com.android.settings', label: 'Settings', isSystem: true },
];

const STATUS_LABELS: Record<ConnectionStatus, string> = {
  disconnected: 'Disconnected',
  preparing: 'Preparing VPN',
  connecting: 'Connecting',
  connected: 'Connected',
  disconnecting: 'Disconnecting',
  failed: 'Failed',
};

function timestamp(): string {
  const now = new Date();
  const pad = (value: number) => String(value).padStart(2, '0');
  return `[${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}]`;
}

interface ScriptStep {
  delayMs: number;
  run: () => void;
}

export class MockOpenRungVpn implements OpenRungVpnModule {
  private state: NativeVpnState = {
    status: 'disconnected',
    relayLabel: null,
    lastError: null,
    logLines: [],
    recents: [],
  };

  private listeners = new Set<(state: NativeVpnState) => void>();
  private timers: Array<ReturnType<typeof setTimeout>> = [];
  private readonly clientId = uuid4();
  private sessionId: string | null = null;

  private trafficListeners = new Set<(stats: TrafficStats) => void>();
  private trafficTimer: ReturnType<typeof setInterval> | null = null;
  private traffic: TrafficStats | null = null;

  private splitTunnel: SplitTunnelConfig = { mode: 'off', packages: [] };
  private persistedLog: string[] = [];

  subscribe(listener: (state: NativeVpnState) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  subscribeTraffic(listener: (stats: TrafficStats) => void): () => void {
    this.trafficListeners.add(listener);
    return () => {
      this.trafficListeners.delete(listener);
    };
  }

  prepare(): Promise<boolean> {
    return Promise.resolve(true);
  }

  connect(brokerUrl: string, targetCountry: string | null): Promise<void> {
    this.cancelScript();
    this.stopTrafficSimulation(false);
    this.sessionId = uuid4();

    const code = targetCountry ? targetCountry.trim().toUpperCase() : 'JP';
    const countryName = displayName(code) ?? code;
    const geo = centroid(code);
    // Production shows the broker-served relay.locationLabel() ("City, Country"); the mock knows
    // a city only for the default Tokyo relay and falls back to the country name otherwise, like
    // production does when the broker hasn't sent a city.
    const relayLabel = code === 'JP' ? 'Tokyo, Japan' : countryName;
    const relayId = `${code.toLowerCase()}-volunteer-1`;

    this.setStatus('preparing', { relayLabel: null, lastError: null });
    this.runScript([
      {
        delayMs: 300,
        run: () => {
          this.setStatus('connecting');
          this.appendLog(`fetching relays from ${brokerUrl}`);
        },
      },
      {
        delayMs: 700,
        run: () => {
          this.appendLog('broker returned 3 relays; 3 usable');
          if (targetCountry) {
            this.appendLog(`connecting to a volunteer in ${countryName}`);
          }
        },
      },
      {
        delayMs: 1000,
        run: () => {
          this.appendLog(`trying relay ${relayId} at 203.0.113.10:443`);
          this.appendLog('checking relay TCP reachability');
        },
      },
      {
        delayMs: 1500,
        run: () => {
          this.appendLog('verifying internet access through the VPN');
        },
      },
      {
        delayMs: 2300,
        run: () => {
          this.appendLog('internet access verified in 812 ms');
          this.setStatus('connected', { relayLabel: null, lastError: null });
          this.startTrafficSimulation();
        },
      },
      {
        delayMs: 2600,
        run: () => {
          // Production applies the broker-served relay location right after CONNECTED, then
          // records the recent node at the curated centroid when the country is known; the mock
          // keeps a small delay so the label visibly follows the status change.
          this.state = { ...this.state, relayLabel };
          this.recordRecent({
            countryCode: code,
            label: relayLabel,
            latitude: geo?.latitude ?? 0,
            longitude: geo?.longitude ?? 0,
          });
          this.emit();
        },
      },
    ]);
    return Promise.resolve();
  }

  disconnect(): Promise<void> {
    this.cancelScript();
    this.stopTrafficSimulation(true);
    this.setStatus('disconnecting');
    this.runScript([
      {
        delayMs: 300,
        run: () => {
          this.sessionId = null;
          this.setStatus('disconnected', { relayLabel: null, lastError: null });
        },
      },
    ]);
    return Promise.resolve();
  }

  getState(): Promise<NativeVpnState> {
    return Promise.resolve(this.snapshot());
  }

  getIdentity(): Promise<NativeIdentity> {
    return Promise.resolve({ clientId: this.clientId, sessionId: this.sessionId });
  }

  getTrafficStats(): Promise<TrafficStats | null> {
    return Promise.resolve(this.traffic ? { ...this.traffic } : null);
  }

  measureLatency(targets: LatencyTarget[], _timeoutMs: number): Promise<LatencyMeasurement> {
    const results = targets.map(target => {
      const reachable = Math.random() >= 0.1; // ~10% of relays unreachable
      return {
        id: target.id,
        latencyMs: reachable ? Math.round(40 + Math.random() * 280) : null,
        reachable,
      };
    });
    // Standalone timer (not this.timers): a connect/disconnect mid-test must not
    // cancel the resolution and leave the caller hanging.
    return new Promise(resolve => {
      setTimeout(
        () => resolve({ viaTunnel: this.state.status === 'connected', results }),
        400 + Math.random() * 400,
      );
    });
  }

  getInstalledApps(): Promise<InstalledApp[]> {
    return Promise.resolve(MOCK_APPS.map(app => ({ ...app })));
  }

  getSplitTunnelConfig(): Promise<SplitTunnelConfig> {
    return Promise.resolve({ ...this.splitTunnel, packages: [...this.splitTunnel.packages] });
  }

  setSplitTunnelConfig(config: SplitTunnelConfig): Promise<{ needsReconnect: boolean }> {
    const changed =
      config.mode !== this.splitTunnel.mode ||
      config.packages.length !== this.splitTunnel.packages.length ||
      config.packages.some(pkg => !this.splitTunnel.packages.includes(pkg));
    this.splitTunnel = { mode: config.mode, packages: [...config.packages] };
    const active =
      this.state.status === 'connected' ||
      this.state.status === 'connecting' ||
      this.state.status === 'preparing';
    return Promise.resolve({ needsReconnect: changed && active });
  }

  getPersistedLog(): Promise<string[]> {
    return Promise.resolve([...this.persistedLog]);
  }

  clearPersistedLog(): Promise<void> {
    this.persistedLog = [];
    return Promise.resolve();
  }

  private startTrafficSimulation(): void {
    this.stopTrafficSimulation(false);
    // Random-walk speeds so the UI shows plausible movement: down ~200 KB/s–6 MB/s,
    // up roughly an eighth of down.
    let downBps = 400_000 + Math.random() * 1_200_000;
    let upTotalBytes = 0;
    let downTotalBytes = 0;
    this.trafficTimer = setInterval(() => {
      downBps = Math.min(6_000_000, Math.max(200_000, downBps * (0.7 + Math.random() * 0.6)));
      const upBps = Math.max(25_000, downBps / (6 + Math.random() * 4));
      downTotalBytes += downBps * (TRAFFIC_INTERVAL_MS / 1000);
      upTotalBytes += upBps * (TRAFFIC_INTERVAL_MS / 1000);
      this.traffic = {
        upBps: Math.round(upBps),
        downBps: Math.round(downBps),
        upTotalBytes: Math.round(upTotalBytes),
        downTotalBytes: Math.round(downTotalBytes),
        updatedAtMs: Date.now(),
      };
      this.emitTraffic(this.traffic);
    }, TRAFFIC_INTERVAL_MS);
  }

  /** Stops the traffic feed; when `emitZero`, sends the contract's final zeroed sample. */
  private stopTrafficSimulation(emitZero: boolean): void {
    if (this.trafficTimer != null) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = null;
    }
    const wasRunning = this.traffic != null;
    this.traffic = null;
    if (emitZero && wasRunning) {
      this.emitTraffic({
        upBps: 0,
        downBps: 0,
        upTotalBytes: 0,
        downTotalBytes: 0,
        updatedAtMs: Date.now(),
      });
    }
  }

  private emitTraffic(stats: TrafficStats): void {
    for (const listener of this.trafficListeners) {
      listener({ ...stats });
    }
  }

  private runScript(steps: ScriptStep[]): void {
    for (const step of steps) {
      this.timers.push(setTimeout(step.run, step.delayMs));
    }
  }

  private cancelScript(): void {
    for (const timer of this.timers) {
      clearTimeout(timer);
    }
    this.timers = [];
  }

  private setStatus(
    status: ConnectionStatus,
    overrides: { relayLabel?: string | null; lastError?: string | null } = {},
  ): void {
    this.state = {
      ...this.state,
      status,
      relayLabel: overrides.relayLabel !== undefined ? overrides.relayLabel : this.state.relayLabel,
      lastError: overrides.lastError !== undefined ? overrides.lastError : this.state.lastError,
    };
    // Production setStatus appends the (localized) status label as a log line.
    this.appendLog(STATUS_LABELS[status]);
  }

  private appendLog(message: string): void {
    const logLines = [...this.state.logLines, `${timestamp()} ${message}`].slice(-MAX_LOG_LINES);
    this.state = { ...this.state, logLines };
    // Production mirrors every live line into the scrubbed persisted log (cap 1000).
    this.persistedLog = [...this.persistedLog, `${timestamp()} ${mockScrub(message)}`].slice(
      -MAX_PERSISTED_LOG_LINES,
    );
    this.emit();
  }

  private recordRecent(node: RecentNode): void {
    const recents = [
      node,
      ...this.state.recents.filter(recent => recent.countryCode !== node.countryCode),
    ].slice(0, MAX_RECENTS);
    this.state = { ...this.state, recents };
  }

  private snapshot(): NativeVpnState {
    return {
      ...this.state,
      logLines: [...this.state.logLines],
      recents: this.state.recents.map(recent => ({ ...recent })),
    };
  }

  private emit(): void {
    const snapshot = this.snapshot();
    for (const listener of this.listeners) {
      listener(snapshot);
    }
  }
}
