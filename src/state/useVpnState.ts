import { useCallback, useEffect } from 'react';
import { AppConfig } from '../config';
import { OpenRungVpn, subscribeTrafficStats, subscribeVpnState } from '../native/OpenRungVpn';
import { applyNativeState, applyTrafficStats, recordLastExit, useAppState } from './store';
import type { AppState } from './store';

export interface VpnStateHook {
  state: AppState;
  /** preparing | connecting | disconnecting */
  isWorking: boolean;
  /** connected */
  isConnected: boolean;
  /** Start (or switch) the tunnel; country: ISO alpha-2 or omitted/null = broker picks. */
  connect: (country?: string | null) => Promise<void>;
  disconnect: () => Promise<void>;
  /**
   * Mirrors production `beginConnect`: request OS consent via prepare(), then start the tunnel.
   * Production proceeds with the start on ANY return from the consent flow (a declined dialog
   * simply makes the service fail and the status comes back through the store), so the prepare
   * result/failure is deliberately not gated on.
   */
  prepareAndConnect: (country?: string | null) => Promise<void>;
}

/**
 * Wires native VPN events into the store: on mount, seeds the native slice via `getState()` and
 * subscribes to `openrungStateChanged`; exposes derived flags and the connect/disconnect actions.
 */
export function useVpnState(): VpnStateHook {
  const state = useAppState();

  useEffect(() => {
    let mounted = true;
    OpenRungVpn.getState()
      .then(nativeState => {
        if (mounted) {
          applyNativeState(nativeState);
        }
      })
      .catch(() => {
        // Native state stays at the store default until the first event arrives.
      });
    OpenRungVpn.getTrafficStats()
      .then(traffic => {
        if (mounted && traffic != null) {
          applyTrafficStats(traffic);
        }
      })
      .catch(() => {
        // Traffic stays null until the first event arrives.
      });
    const unsubscribe = subscribeVpnState(applyNativeState);
    const unsubscribeTraffic = subscribeTrafficStats(applyTrafficStats);
    return () => {
      mounted = false;
      unsubscribe();
      unsubscribeTraffic();
    };
  }, []);

  const connect = useCallback(
    (country?: string | null) => OpenRungVpn.connect(AppConfig.DEFAULT_BROKER_URL, country ?? null),
    [],
  );

  const disconnect = useCallback(() => OpenRungVpn.disconnect(), []);

  const prepareAndConnect = useCallback(
    async (country?: string | null) => {
      // Remember the REQUESTED target (not the resolved relay) so auto-connect can replay it.
      recordLastExit(country ?? null);
      try {
        await OpenRungVpn.prepare();
      } catch {
        // See doc comment: production starts the service on any consent-flow return.
      }
      await connect(country ?? null);
    },
    [connect],
  );

  const status = state.native.status;
  const isWorking =
    status === 'preparing' || status === 'connecting' || status === 'disconnecting';
  const isConnected = status === 'connected';

  return { state, isWorking, isConnected, connect, disconnect, prepareAndConnect };
}
