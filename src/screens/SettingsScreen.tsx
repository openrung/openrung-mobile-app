/**
 * Settings tab. Large title (it's a root tab now — no back arrow), then
 * sectioned panels:
 *   GENERAL         — language picker
 *   CONNECTION      — auto-connect on launch, remember last exit
 *   DIAGNOSTICS     — volunteer speed test (down+up), exit IP check, debug console
 *   NETWORK TOOLBOX — curated third-party leak/speed test links (open in browser)
 * Version and licenses live on the About tab. The language picker mirrors the
 * production dropdown semantics with a dark-styled modal list.
 */
import React, { useEffect, useState } from 'react';
import {
  Linking,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ExitIpRow } from '../components/ExitIpRow';
import { SettingPanel } from '../components/SettingPanel';
import { SpeedTestRow } from '../components/SpeedTestRow';
import { ToggleSwitch } from '../components/ToggleSwitch';
import { AppConfig } from '../config';
import { languageOptions, useLanguage, useStrings, type Strings } from '../i18n';
import { OpenRungVpn } from '../native/OpenRungVpn';
import type { SplitTunnelConfig } from '../native/types';
import { setAutoConnectEnabled, setRememberExitEnabled } from '../state/store';
import { useVpnState } from '../state/useVpnState';
import { monoFont, palette, tokens } from '../theme';

export interface SettingsScreenProps {
  onOpenDebug: () => void;
  onOpenSplitTunnel: () => void;
}

function splitTunnelSubtitle(s: Strings, config: SplitTunnelConfig | null): string {
  if (config == null || config.mode === 'off') {
    return s.splitTunnelSubtitleOff;
  }
  return config.mode === 'proxyOnly'
    ? s.splitTunnelSubtitleAllow(config.packages.length)
    : s.splitTunnelSubtitleDeny(config.packages.length);
}

const TOOLBOX_TITLES: Record<(typeof AppConfig.TOOLBOX_LINKS)[number]['id'], (s: Strings) => string> = {
  ipCheck: s => s.toolboxIpCheck,
  dnsLeak: s => s.toolboxDnsLeak,
  webrtcLeak: s => s.toolboxWebrtcLeak,
  speedTest: s => s.toolboxSpeedTest,
};

export function SettingsScreen({
  onOpenDebug,
  onOpenSplitTunnel,
}: SettingsScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { state, isConnected } = useVpnState();

  // Android-only per-app VPN summary; refreshed when Settings mounts (config lives natively).
  const [splitTunnel, setSplitTunnel] = useState<SplitTunnelConfig | null>(null);
  useEffect(() => {
    if (Platform.OS !== 'android') {
      return;
    }
    let mounted = true;
    OpenRungVpn.getSplitTunnelConfig()
      .then(config => {
        if (mounted) {
          setSplitTunnel(config);
        }
      })
      .catch(() => {});
    return () => {
      mounted = false;
    };
  }, []);

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={[
        styles.content,
        {
          paddingTop: insets.top + 24,
          paddingBottom: tokens.tabBarHeight + insets.bottom + 24,
        },
      ]}
    >
      <Text style={styles.title}>{s.settingsTitle}</Text>

      <Text style={styles.sectionHeader}>{s.settingsGeneralHeader.toUpperCase()}</Text>
      <SettingPanel
        title={s.languageSettingTitle}
        subtitle={s.languageSettingSubtitle}
        trailing={<LanguagePicker />}
      />

      <Text style={styles.sectionHeader}>{s.settingsConnectionHeader.toUpperCase()}</Text>
      <SettingPanel
        title={s.autoConnectTitle}
        subtitle={s.autoConnectSubtitle}
        trailing={
          <ToggleSwitch
            value={state.autoConnectEnabled}
            onValueChange={setAutoConnectEnabled}
            accessibilityLabel={s.autoConnectTitle}
          />
        }
      />
      <SettingPanel
        title={s.rememberExitTitle}
        subtitle={s.rememberExitSubtitle}
        trailing={
          <ToggleSwitch
            value={state.rememberExitEnabled}
            onValueChange={setRememberExitEnabled}
            accessibilityLabel={s.rememberExitTitle}
          />
        }
      />
      {Platform.OS === 'android' ? (
        <SettingPanel
          title={s.splitTunnelTitle}
          subtitle={splitTunnelSubtitle(s, splitTunnel)}
          onPress={onOpenSplitTunnel}
        />
      ) : null}

      <Text style={styles.sectionHeader}>{s.settingsDiagnosticsHeader.toUpperCase()}</Text>
      <SpeedTestRow isConnected={isConnected} />
      <ExitIpRow isConnected={isConnected} />
      <SettingPanel
        title={s.debugSettingTitle}
        subtitle={s.debugSettingSubtitle}
        onPress={onOpenDebug}
      />

      <Text style={styles.sectionHeader}>{s.settingsToolboxHeader.toUpperCase()}</Text>
      {AppConfig.TOOLBOX_LINKS.map(link => (
        <SettingPanel
          key={link.id}
          title={TOOLBOX_TITLES[link.id](s)}
          subtitle={s.toolboxSubtitle}
          onPress={() => {
            Linking.openURL(link.url).catch(() => {
              // Ignore: no browser available.
            });
          }}
        />
      ))}
    </ScrollView>
  );
}

/**
 * Trailing language picker: a text button showing the current selection that
 * opens a dark-styled modal list of the 10 production language options
 * (system default + 9 languages). Selection persists via the i18n layer.
 */
function LanguagePicker(): React.JSX.Element {
  const { strings, languageTag, setLanguage } = useLanguage();
  const [open, setOpen] = useState(false);

  const selected =
    languageOptions.find(option => option.tag === languageTag) ?? languageOptions[0];

  return (
    <>
      <Pressable
        onPress={() => setOpen(true)}
        style={styles.languageButton}
        accessibilityRole="button"
      >
        <Text style={styles.languageButtonLabel}>{selected.label(strings)}</Text>
      </Pressable>
      <Modal
        visible={open}
        transparent
        animationType="none"
        onRequestClose={() => setOpen(false)}
      >
        <Pressable style={styles.modalBackdrop} onPress={() => setOpen(false)}>
          <View style={styles.modalMenu}>
            {languageOptions.map(option => (
              <Pressable
                key={option.tag === '' ? 'system' : option.tag}
                onPress={() => {
                  setLanguage(option.tag);
                  setOpen(false);
                }}
                style={({ pressed }) => [styles.modalItem, pressed && styles.modalItemPressed]}
                accessibilityRole="button"
              >
                <Text style={styles.modalItemLabel}>{option.label(strings)}</Text>
              </Pressable>
            ))}
          </View>
        </Pressable>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
  },
  content: {
    paddingHorizontal: tokens.edge,
    gap: 14,
  },
  title: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 26,
    marginBottom: 6,
  },
  sectionHeader: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 11,
    letterSpacing: 1.5,
    marginTop: 8,
  },
  // Material TextButton-ish: label-only button, terminal green mono.
  languageButton: {
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  languageButtonLabel: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 14,
  },
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modalMenu: {
    minWidth: 220,
    borderRadius: tokens.radiusSm,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    paddingVertical: 8,
    overflow: 'hidden',
  },
  modalItem: {
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  modalItemPressed: {
    backgroundColor: palette.fabBackground,
  },
  modalItemLabel: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 14,
  },
});
