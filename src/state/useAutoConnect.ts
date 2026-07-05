import { useEffect, useRef } from 'react';
import { AppConfig } from '../config';
import { OpenRungVpn } from '../native/OpenRungVpn';
import { useAppState } from './store';

/**
 * One-shot auto-connect on app launch, mounted once from the app root. The decision is
 * made exactly once, when the persisted preferences first finish hydrating: if
 * auto-connect is enabled AND the native side reports `disconnected` (asked directly via
 * `getState()`, not the store default, so an OS-restored tunnel is never doubled up),
 * start the tunnel toward the remembered exit (or broker-picks when none).
 *
 * A toggle flipped later in Settings deliberately does NOT trigger a connect — it only
 * takes effect on the next launch.
 */
export function useAutoConnect(): void {
  const { prefsHydrated, autoConnectEnabled, rememberExitEnabled, lastExitCountry } =
    useAppState();
  const decided = useRef(false);

  useEffect(() => {
    if (!prefsHydrated || decided.current) {
      return;
    }
    decided.current = true;
    if (!autoConnectEnabled) {
      return;
    }
    (async () => {
      try {
        const native = await OpenRungVpn.getState();
        if (native.status !== 'disconnected') {
          return;
        }
        try {
          await OpenRungVpn.prepare();
        } catch {
          // Same semantics as prepareAndConnect: proceed on any consent-flow return.
        }
        await OpenRungVpn.connect(
          AppConfig.DEFAULT_BROKER_URL,
          rememberExitEnabled ? lastExitCountry : null,
        );
      } catch {
        // Failures surface through openrungStateChanged events like any connect.
      }
    })();
  }, [prefsHydrated, autoConnectEnabled, rememberExitEnabled, lastExitCountry]);
}
