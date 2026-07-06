import { useCallback, useEffect } from 'react';
import { AppConfig } from '../config';
import { OpenRungVpn, subscribeVpnState } from '../native/OpenRungVpn';
import { applyNativeState, useAppState } from './store';
import type { AppState } from './store';

export interface VpnStateHook {
  state: AppState;
  /** preparing | connecting | disconnecting */
  isWorking: boolean;
  /** connected */
  isConnected: boolean;
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

/**
 * Wires native VPN events into the store: on mount, seeds the native slice via `getState()` and
 * subscribes to `openrungStateChanged`; exposes derived flags and the connect/disconnect actions.
 */
export function useVpnState(): VpnStateHook {
  const state = useAppState();

  useEffect(() => {
    let mounted = true;
    let receivedEvent = false;
    // Subscribe FIRST so no event is missed, and track whether one has arrived: a slow getState()
    // seed must not clobber a fresher event that landed while it was in flight (e.g. mounting during
    // a connecting -> connected transition).
    const unsubscribe = subscribeVpnState(nativeState => {
      receivedEvent = true;
      applyNativeState(nativeState);
    });
    OpenRungVpn.getState()
      .then(nativeState => {
        if (mounted && !receivedEvent) {
          applyNativeState(nativeState);
        }
      })
      .catch(() => {
        // Native state stays at the store default until the first event arrives.
      });
    return () => {
      mounted = false;
      unsubscribe();
    };
  }, []);

  const connect = useCallback(
    (country?: string | null, relayId?: string | null) =>
      OpenRungVpn.connect(AppConfig.DEFAULT_BROKER_URL, country ?? null, relayId ?? null),
    [],
  );

  const disconnect = useCallback(() => OpenRungVpn.disconnect(), []);

  const prepareAndConnect = useCallback(
    async (country?: string | null, relayId?: string | null) => {
      try {
        await OpenRungVpn.prepare();
      } catch {
        // See doc comment: production starts the service on any consent-flow return.
      }
      await connect(country ?? null, relayId ?? null);
    },
    [connect],
  );

  const status = state.native.status;
  const isWorking =
    status === 'preparing' || status === 'connecting' || status === 'disconnecting';
  const isConnected = status === 'connected';

  return { state, isWorking, isConnected, connect, disconnect, prepareAndConnect };
}
