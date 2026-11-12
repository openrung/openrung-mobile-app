/**
 * Desktop-only Settings row for the client's capture mode, wrapped around the local proxy rows.
 *
 * The desktop client normally serves a loopback proxy that the system proxy points at, so only
 * proxy-aware apps are carried. Where its host can also capture the whole device through a TUN
 * interface, this row offers that as a switch. Turning it on may restart the client with
 * administrator rights — the host says so in `requiresRestart`, and the row warns before the
 * switch is used. The mode belongs to a session, so the switch is locked while a tunnel is up.
 *
 * The children are the local proxy rows. In TUN mode the client serves no local proxy, so they
 * are left out.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';

import { useStrings } from '../i18n';
import type { DesktopTunnelMode, OpenRungDesktopModule } from '../native/OpenRungDesktop';
import { SettingPanel } from './SettingPanel';
import { TerminalSwitch } from './TerminalSwitch';

export interface DesktopTunnelModeSectionProps {
  desktop: OpenRungDesktopModule;
  /** No tunnel is up or coming up, so the mode may change. */
  isIdle: boolean;
  children: React.ReactNode;
}

export function DesktopTunnelModeSection({
  desktop,
  isIdle,
  children,
}: DesktopTunnelModeSectionProps): React.JSX.Element {
  const s = useStrings();
  const [info, setInfo] = useState<DesktopTunnelMode | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    // An older host has no capture mode to report: proxy mode, and no switch.
    desktop.getTunnelMode?.().then(
      loaded => {
        if (mounted.current) {
          setInfo(loaded);
        }
      },
      () => {
        // A host that cannot say stays in proxy mode, with no switch.
      },
    );
    return () => {
      mounted.current = false;
    };
  }, [desktop]);

  const onChange = useCallback(
    (on: boolean) => {
      const { getTunnelMode, setTunnelMode } = desktop;
      if (getTunnelMode == null || setTunnelMode == null) {
        return;
      }
      setBusy(true);
      setError(null);
      setTunnelMode(on ? 'tun' : 'proxy')
        .then(() => getTunnelMode())
        .then(
          loaded => {
            if (mounted.current) {
              setInfo(loaded);
            }
          },
          (failure: unknown) => {
            if (mounted.current) {
              setError(failure instanceof Error ? failure.message : String(failure));
            }
          },
        )
        .finally(() => {
          if (mounted.current) {
            setBusy(false);
          }
        });
    },
    [desktop],
  );

  const tunOn = info?.mode === 'tun';
  let subtitle: string;
  if (error != null) {
    subtitle = error;
  } else if (!isIdle) {
    subtitle = s.desktopTunModeRequiresDisconnect;
  } else if (tunOn) {
    subtitle = s.desktopTunModeSubtitleOn;
  } else if (info?.requiresRestart === true) {
    subtitle = `${s.desktopTunModeSubtitleOff} ${s.desktopTunModeRestartNote}`;
  } else {
    subtitle = s.desktopTunModeSubtitleOff;
  }

  return (
    <>
      {info?.available === true ? (
        <SettingPanel
          title={s.desktopTunModeTitle}
          subtitle={subtitle}
          trailing={<TerminalSwitch value={tunOn} onChange={onChange} disabled={!isIdle || busy} />}
        />
      ) : null}
      {tunOn ? null : children}
    </>
  );
}
