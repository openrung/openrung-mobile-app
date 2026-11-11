import { useCallback, useEffect } from 'react';
import { AppConfig } from '../config';
import {
  OpenRungVpn,
  subscribeConnectRequests,
  subscribeVpnState,
} from '../native/OpenRungVpn';
import {
  applyNativeState,
  flushSplitTunnelPush,
  getAppState,
  useAppState,
} from './store';
import type { AppState } from './store';

export interface VpnActions {
  /**
   * Start (or switch) the tunnel; country: ISO alpha-2 or omitted/null = broker picks.
   * relayId: connect to that exact broker relay (takes precedence over country).
   */
  connect: (country?: string | null, relayId?: string | null) => Promise<void>;
  disconnect: () => Promise<void>;
  /**
   * Mirrors production `beginConnect`: request OS consent via prepare(), then start the tunnel.
   * Production proceeds with the start on ANY return from the consent flow (a declined dialog
   * simply makes the service fail and the status comes back through the store), so the prepare
   * result/failure is deliberately not gated on.
   */
  prepareAndConnect: (country?: string | null, relayId?: string | null) => Promise<void>;
}

interface VpnStateHook extends VpnActions {
  state: AppState;
  /** preparing | connecting | disconnecting */
  isWorking: boolean;
  /** connected */
  isConnected: boolean;
}

/**
 * One app-lifetime subscription mirrors native VPN events into the store, no matter how many
 * components read from it: on first use it subscribes to `openrungStateChanged`, then seeds the
 * native slice via `getState()`. Subscribing FIRST means no event is missed, and the seed is
 * skipped once an event has arrived: a slow getState() must not clobber a fresher event that
 * landed while it was in flight (e.g. wiring up during a connecting -> connected transition).
 * The subscription is deliberately never torn down — components come and go, the mirror stays.
 */
let nativeStateWired = false;

/**
 * Start (or switch) the tunnel; country: ISO alpha-2 or null = broker picks. relayId: connect to
 * that exact broker relay (takes precedence over country). Module-level so the widget handoff and
 * the hook below share one path.
 */
async function connectVpn(country: string | null, relayId: string | null): Promise<void> {
  // Persist any just-changed split-tunnel config before the native connect reads its snapshot,
  // so a setting flipped moments before tapping Connect takes effect this session. No-op when
  // no push is pending, so the normal connect path is unaffected.
  await flushSplitTunnelPush();
  return OpenRungVpn.connect(AppConfig.DEFAULT_BROKER_URL, country, relayId);
}

/**
 * Mirrors production `beginConnect`: request OS consent via prepare(), then start the tunnel.
 * Production proceeds with the start on ANY return from the consent flow (a declined dialog
 * simply makes the service fail and the status comes back through the store), so the prepare
 * result/failure is deliberately not gated on.
 */
async function prepareAndConnectVpn(
  country: string | null,
  relayId: string | null,
): Promise<void> {
  try {
    await OpenRungVpn.prepare();
  } catch {
    // See doc comment: production starts the service on any consent-flow return.
  }
  await connectVpn(country, relayId);
}

function ensureNativeStateWired(): void {
  if (nativeStateWired) {
    return;
  }
  nativeStateWired = true;
  // Subscribed BEFORE the state subscription on purpose: registering the first listener is what
  // makes native start emitting, and it hands over a pending widget tap right then — both
  // listeners must already exist when that event lands.
  subscribeConnectRequests(() => {
    // iOS home-screen widget tap (contract §3). Native forwards it only while the tunnel is down,
    // and the store check below is the same guard against a request that raced a connect. No
    // target: the broker/connectcore picks the relay, exactly like the in-app CONNECT button.
    const status = getAppState().native.status;
    if (status !== 'disconnected' && status !== 'failed') {
      return;
    }
    prepareAndConnectVpn(null, null).catch(() => {
      // Failures surface through the mirrored native state like any other connect.
    });
  });
  let receivedEvent = false;
  subscribeVpnState(nativeState => {
    receivedEvent = true;
    applyNativeState(nativeState);
  });
  OpenRungVpn.getState()
    .then(nativeState => {
      if (!receivedEvent) {
        applyNativeState(nativeState);
      }
    })
    .catch(() => {
      // Native state stays at the store default until the first event arrives.
    });
}

/**
 * Connect/disconnect actions plus the native-event wiring, without subscribing to any state:
 * components that only trigger transitions (or select their own slices via `useAppSelector`)
 * use this and skip the re-render-on-every-event cost of `useVpnState`.
 */
export function useVpnActions(): VpnActions {
  useEffect(() => {
    ensureNativeStateWired();
  }, []);

  const connect = useCallback(
    (country?: string | null, relayId?: string | null) =>
      connectVpn(country ?? null, relayId ?? null),
    [],
  );

  const disconnect = useCallback(() => OpenRungVpn.disconnect(), []);

  const prepareAndConnect = useCallback(
    (country?: string | null, relayId?: string | null) =>
      prepareAndConnectVpn(country ?? null, relayId ?? null),
    [],
  );

  return { connect, disconnect, prepareAndConnect };
}

/**
 * Full-state variant: subscribes to the ENTIRE store, so the component re-renders on every
 * mirrored native event — including log lines. Only for consumers that render the log itself
 * (Debug screen); everything else should pair `useVpnActions` with `useAppSelector`.
 */
export function useVpnState(): VpnStateHook {
  const state = useAppState();
  const actions = useVpnActions();

  const status = state.native.status;
  const isWorking =
    status === 'preparing' || status === 'connecting' || status === 'disconnecting';
  const isConnected = status === 'connected';

  return { state, isWorking, isConnected, ...actions };
}
