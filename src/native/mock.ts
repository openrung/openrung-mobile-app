import { centroid, displayName } from '../model/countryGeo';
import { uuid4 } from '../net/telemetryClient';
import type {
  ConnectionStatus,
  NativeIdentity,
  NativeVpnState,
  OpenRungVpnModule,
  RecentNode,
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

  subscribe(listener: (state: NativeVpnState) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  prepare(): Promise<boolean> {
    return Promise.resolve(true);
  }

  connect(brokerUrl: string, targetCountry: string | null): Promise<void> {
    this.cancelScript();
    this.sessionId = uuid4();

    const code = targetCountry ? targetCountry.trim().toUpperCase() : 'JP';
    const countryName = displayName(code) ?? code;
    const geo = centroid(code);
    // Production shows geo.locationLabel() ("City, Country"); the mock knows a city only for the
    // default Tokyo relay and falls back to the country name otherwise, like production does.
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
        },
      },
      {
        delayMs: 2600,
        run: () => {
          // Production resolves the relay location asynchronously after CONNECTED, then records
          // the recent node at the curated centroid when the country is known.
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
