/**
 * Settings row for the exit IP check: fetches what the internet sees (egress
 * IP, location, network) through the active tunnel. The enabled-only-while-
 * connected gate is a PRIVACY control, not just UX — disconnected, the lookup
 * would hand the user's real IP to the third-party endpoint (see
 * AppConfig.EXIT_IP_INFO_URL). Runs only on explicit tap; result is
 * deliberately not persisted (it's a point-in-time check).
 */
import React, { useCallback, useState } from 'react';

import { AppConfig } from '../config';
import { useStrings } from '../i18n';
import { fetchExitIpInfo, type ExitIpInfo } from '../net/ipInfoClient';
import { RunButton } from './RunButton';
import { SettingPanel } from './SettingPanel';

export interface ExitIpRowProps {
  isConnected: boolean;
}

function describe(info: ExitIpInfo): string {
  const location = [info.city, info.country].filter(part => part != null).join(', ');
  return [location, info.org].filter(part => part != null && part.length > 0).join(' · ');
}

export function ExitIpRow({ isConnected }: ExitIpRowProps): React.JSX.Element {
  const s = useStrings();
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState<ExitIpInfo | null>(null);
  const [error, setError] = useState<string | null>(null);

  const subtitle = running
    ? s.exitIpRunning
    : error != null
      ? s.exitIpError(error)
      : result != null
        ? s.exitIpResult(result.ip, describe(result))
        : !isConnected
          ? s.exitIpRequiresConnection
          : s.exitIpReady;

  const onRun = useCallback(() => {
    setRunning(true);
    setResult(null);
    setError(null);
    (async () => {
      try {
        setResult(await fetchExitIpInfo(AppConfig.EXIT_IP_INFO_URL));
      } catch (caught) {
        setError(caught instanceof Error ? caught.message || caught.name : String(caught));
      } finally {
        setRunning(false);
      }
    })();
  }, []);

  return (
    <SettingPanel
      title={s.exitIpTitle}
      subtitle={subtitle}
      trailing={
        <RunButton label={s.exitIpAction} onPress={onRun} enabled={isConnected && !running} />
      }
    />
  );
}
