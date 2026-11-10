/**
 * Desktop-only Settings rows for the client's local proxy. Desktop has no OS-level VPN profile:
 * while connected the system proxy points at a loopback endpoint, and a terminal session opts in
 * by running a generated shell command. The rows show that endpoint and hand out the commands
 * through copy buttons:
 *
 *  - Endpoint: host:port, and whether it is serving right now;
 *  - Endpoint persistence / Shell integration: only when the host reports a problem with either;
 *  - Enable in this shell / Restore this shell: the two commands, on systems that have them.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';

import { useStrings } from '../i18n';
import type { DesktopProxyInfo, OpenRungDesktopModule } from '../native/OpenRungDesktop';
import { monoFont, palette } from '../theme';
import { SettingPanel } from './SettingPanel';

/** How long a button reads "Copied" after a successful copy. */
const COPIED_FEEDBACK_MS = 1500;

type CopyTarget = 'endpoint' | 'enable' | 'disable';

export interface DesktopProxySectionProps {
  desktop: OpenRungDesktopModule;
  isConnected: boolean;
}

export function DesktopProxySection({
  desktop,
  isConnected,
}: DesktopProxySectionProps): React.JSX.Element {
  const s = useStrings();
  const [info, setInfo] = useState<DesktopProxyInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<CopyTarget | null>(null);
  const copiedTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let active = true;
    desktop.getProxyInfo().then(
      loaded => {
        if (active) {
          setInfo(loaded);
        }
      },
      (failure: unknown) => {
        if (active) {
          setError(failure instanceof Error ? failure.message : String(failure));
        }
      },
    );
    return () => {
      active = false;
      if (copiedTimer.current != null) {
        clearTimeout(copiedTimer.current);
      }
    };
  }, [desktop]);

  const copy = useCallback(
    (target: CopyTarget, text: string) => {
      desktop.copyText(text).then(
        () => {
          setCopied(target);
          if (copiedTimer.current != null) {
            clearTimeout(copiedTimer.current);
          }
          copiedTimer.current = setTimeout(() => setCopied(null), COPIED_FEEDBACK_MS);
        },
        () => {
          // Nothing was copied; the button simply keeps reading "Copy".
        },
      );
    },
    [desktop],
  );

  const copyButton = (target: CopyTarget, text: string, disabled: boolean = false) => (
    <Pressable
      onPress={() => copy(target, text)}
      disabled={disabled}
      style={styles.copyButton}
      accessibilityRole="button"
    >
      <Text style={[styles.copyLabel, disabled && styles.copyLabelDisabled]}>
        {copied === target ? s.actionCopied : s.actionCopy}
      </Text>
    </Pressable>
  );

  if (info == null) {
    return (
      <SettingPanel title={s.desktopProxyEndpointTitle} subtitle={error ?? s.desktopProxyPreparing} />
    );
  }

  return (
    <>
      <SettingPanel
        title={s.desktopProxyEndpointTitle}
        subtitle={
          isConnected
            ? s.desktopProxyEndpointConnected(info.endpoint)
            : s.desktopProxyEndpointIdle(info.endpoint)
        }
        trailing={copyButton('endpoint', info.endpoint)}
      />
      {info.persistenceWarning != null ? (
        <SettingPanel title={s.desktopProxyPersistenceTitle} subtitle={info.persistenceWarning} />
      ) : null}
      {info.shellIntegrationError != null ? (
        <SettingPanel title={s.desktopShellIntegrationTitle} subtitle={info.shellIntegrationError} />
      ) : info.shellIntegration ? (
        <>
          <SettingPanel
            title={s.desktopShellEnableTitle}
            subtitle={
              isConnected ? s.desktopShellEnableSubtitle : s.desktopShellEnableRequiresConnection
            }
            // Enabling a shell before the proxy serves would only break that shell's network.
            trailing={copyButton('enable', info.enableCommand, !isConnected)}
          />
          <SettingPanel
            title={s.desktopShellRestoreTitle}
            subtitle={s.desktopShellRestoreSubtitle}
            trailing={copyButton('disable', info.disableCommand)}
          />
        </>
      ) : null}
    </>
  );
}

const styles = StyleSheet.create({
  // Same label-only button as the language picker's.
  copyButton: {
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  copyLabel: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 14,
  },
  copyLabelDisabled: {
    color: palette.dimText,
  },
});
