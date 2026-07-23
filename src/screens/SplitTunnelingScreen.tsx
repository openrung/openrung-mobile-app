/**
 * Split tunneling screen (presets only, no custom rules editor). Master toggle,
 * BYPASS section (local network + the ir/cn country presets), and — Android
 * only, when the app-list module is linked — an APPS section whose "Bypassed
 * apps" row opens a modal picker of installed launcher apps. Changes
 * auto-apply: the store debounces a config push to native, which reconnects
 * the live tunnel to the same target (the footer hint says so). A bad config
 * never breaks connect — native degrades to full-tunnel behavior (contract §1).
 */
import React, { useCallback, useEffect, useState } from 'react';
import {
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ScreenHeader } from '../components/ScreenHeader';
import { SettingPanel } from '../components/SettingPanel';
import { TerminalSwitch } from '../components/TerminalSwitch';
import { useStrings } from '../i18n';
import {
  getInstalledApps,
  isAppListAvailable,
  type InstalledApp,
} from '../native/OpenRungAppList';
import { hydrateSplitTunnel, setSplitTunnel, useAppState } from '../state/store';
import { monoFont, palette, tokens } from '../theme';

export interface SplitTunnelingScreenProps {
  onBack: () => void;
}

/** The v1 country presets, in the normalized order the native generators expect. */
const COUNTRY_ORDER = ['ir', 'cn'] as const;
type CountryCode = (typeof COUNTRY_ORDER)[number];

export function SplitTunnelingScreen({ onBack }: SplitTunnelingScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { splitTunnel } = useAppState();

  useEffect(() => {
    // Re-sync from AsyncStorage (and give native one debounced push) on every visit.
    // hydrateSplitTunnel is best-effort and never rejects.
    hydrateSplitTunnel();
  }, []);

  const toggleCountry = useCallback(
    (code: CountryCode, on: boolean) => {
      // Membership toggles keep the stable ir,cn order regardless of tap order.
      const bypassCountries = COUNTRY_ORDER.filter(preset =>
        preset === code ? on : splitTunnel.bypassCountries.includes(preset),
      );
      setSplitTunnel({ bypassCountries });
    },
    [splitTunnel.bypassCountries],
  );

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + 20, paddingBottom: insets.bottom + 20 },
      ]}
    >
      <ScreenHeader title={s.splitTunnelHeader} onBack={onBack} />

      <SettingPanel
        title={s.splitTunnelMasterTitle}
        subtitle={s.splitTunnelMasterSubtitle}
        trailing={
          <TerminalSwitch
            value={splitTunnel.enabled}
            onChange={enabled => setSplitTunnel({ enabled })}
          />
        }
      />

      <Text style={styles.sectionHeader}>{s.splitTunnelBypassHeader.toUpperCase()}</Text>
      <View style={!splitTunnel.enabled && styles.sectionDimmed}>
        <View style={styles.sectionRows}>
          <SettingPanel
            title={s.splitTunnelLanTitle}
            subtitle={s.splitTunnelLanSubtitle}
            trailing={
              <TerminalSwitch
                value={splitTunnel.bypassLan}
                onChange={bypassLan => setSplitTunnel({ bypassLan })}
                disabled={!splitTunnel.enabled}
              />
            }
          />
          <SettingPanel
            title={s.splitTunnelIranTitle}
            subtitle={s.splitTunnelIranSubtitle}
            trailing={
              <TerminalSwitch
                value={splitTunnel.bypassCountries.includes('ir')}
                onChange={on => toggleCountry('ir', on)}
                disabled={!splitTunnel.enabled}
              />
            }
          />
          <SettingPanel
            title={s.splitTunnelChinaTitle}
            subtitle={s.splitTunnelChinaSubtitle}
            trailing={
              <TerminalSwitch
                value={splitTunnel.bypassCountries.includes('cn')}
                onChange={on => toggleCountry('cn', on)}
                disabled={!splitTunnel.enabled}
              />
            }
          />
        </View>
      </View>

      {Platform.OS === 'android' && isAppListAvailable ? (
        <>
          <Text style={styles.sectionHeader}>{s.splitTunnelAppsHeader.toUpperCase()}</Text>
          <AppPickerRow excludedApps={splitTunnel.excludedApps} />
        </>
      ) : null}

      <Text style={styles.footer}>{s.splitTunnelApplyHint}</Text>
    </ScrollView>
  );
}

/**
 * "Bypassed apps" row + modal picker (the LanguagePicker pattern): a mono list
 * of installed launcher apps, each row `[x] Label` toggling membership in
 * excludedApps, with a loading line while the native query resolves.
 */
function AppPickerRow({ excludedApps }: { excludedApps: string[] }): React.JSX.Element {
  const s = useStrings();
  const [open, setOpen] = useState(false);
  const [apps, setApps] = useState<InstalledApp[] | null>(null);

  const onOpen = useCallback(() => {
    setOpen(true);
    if (apps == null) {
      getInstalledApps()
        .then(loaded => {
          setApps(loaded);
          // Prune entries whose app is no longer installed: the picker only lists installed apps,
          // so a package the user later uninstalled could otherwise never be unchecked and would
          // linger forever in excluded_packages (and in the "N apps" count). Guard on a non-empty
          // result so a spurious empty list never wipes the user's selections.
          if (loaded.length > 0) {
            const installed = new Set(loaded.map(app => app.packageName));
            const pruned = excludedApps.filter(pkg => installed.has(pkg));
            if (pruned.length !== excludedApps.length) {
              setSplitTunnel({ excludedApps: pruned });
            }
          }
        })
        .catch(() => {
          // Best-effort: an unavailable list just shows the empty line.
          setApps([]);
        });
    }
  }, [apps, excludedApps]);

  const toggleApp = useCallback(
    (packageName: string) => {
      const next = excludedApps.includes(packageName)
        ? excludedApps.filter(existing => existing !== packageName)
        : [...excludedApps, packageName];
      setSplitTunnel({ excludedApps: next });
    },
    [excludedApps],
  );

  return (
    <>
      <SettingPanel
        title={s.splitTunnelAppsTitle}
        subtitle={s.splitTunnelAppsSubtitle(excludedApps.length)}
        onPress={onOpen}
      />
      <Modal
        visible={open}
        transparent
        animationType="none"
        onRequestClose={() => setOpen(false)}
      >
        <Pressable style={styles.modalBackdrop} onPress={() => setOpen(false)}>
          <Pressable style={styles.modalMenu}>
            <Text style={styles.modalTitle}>{s.splitTunnelAppPickerTitle}</Text>
            <ScrollView style={styles.modalList}>
              {apps == null ? (
                <Text style={styles.modalNotice}>{s.splitTunnelAppPickerLoading}</Text>
              ) : apps.length === 0 ? (
                <Text style={styles.modalNotice}>{s.splitTunnelAppPickerEmpty}</Text>
              ) : (
                apps.map(app => (
                  <Pressable
                    key={app.packageName}
                    onPress={() => toggleApp(app.packageName)}
                    style={({ pressed }) => [styles.modalItem, pressed && styles.modalItemPressed]}
                    accessibilityRole="checkbox"
                    accessibilityState={{ checked: excludedApps.includes(app.packageName) }}
                  >
                    <Text style={styles.modalItemLabel}>
                      {excludedApps.includes(app.packageName) ? '[x] ' : '[ ] '}
                      {app.label}
                    </Text>
                  </Pressable>
                ))
              )}
            </ScrollView>
            <Pressable
              onPress={() => setOpen(false)}
              style={styles.modalClose}
              accessibilityRole="button"
            >
              <Text style={styles.modalCloseLabel}>{s.splitTunnelAppPickerClose}</Text>
            </Pressable>
          </Pressable>
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
  sectionHeader: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 11,
    letterSpacing: 1.5,
    marginTop: 8,
  },
  // Bypass rows read as inert while the master toggle is off (switches are disabled too).
  sectionDimmed: {
    opacity: 0.45,
  },
  sectionRows: {
    gap: 14,
  },
  footer: {
    alignSelf: 'center',
    marginTop: 8,
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 12,
    textAlign: 'center',
  },
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modalMenu: {
    minWidth: 260,
    maxWidth: '86%',
    maxHeight: '70%',
    borderRadius: tokens.radiusSm,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    paddingVertical: 8,
    overflow: 'hidden',
  },
  modalTitle: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  modalList: {
    flexGrow: 0,
  },
  modalNotice: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 13,
    paddingHorizontal: 16,
    paddingVertical: 12,
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
  modalClose: {
    alignSelf: 'flex-end',
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  modalCloseLabel: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
  },
});
