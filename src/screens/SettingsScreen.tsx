/**
 * Settings tab. Large title (it's a root tab now — no back arrow), then
 * sectioned panels: GENERAL (language, split tunneling, plus per-platform
 * sharing — Android offline APK, iOS TestFlight invite link) and DIAGNOSTICS
 * (speed test link, debug console). The desktop client swaps the row its host
 * does not implement (split tunneling) for a LOCAL PROXY section.
 * Version and licenses live on the About tab. The language
 * picker mirrors the production dropdown semantics with a dark-styled modal
 * list; the speed test row opens an external speed test in the system browser
 * and is enabled only while connected, so it measures the tunnel.
 */
import React, { useCallback, useState } from 'react';
import {
  Alert,
  Linking,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { DesktopProxySection } from '../components/DesktopProxySection';
import { SettingPanel } from '../components/SettingPanel';
import { APP_VERSION, AppConfig } from '../config';
import { languageOptions, useLanguage, useStrings } from '../i18n';
import { edgePadding, layout, useTabSceneColumns } from '../layout';
import {
  apkShareErrorCode,
  isApkShareAvailable,
  shareInstalledApk,
} from '../native/OpenRungApkShare';
import { OpenRungDesktop } from '../native/OpenRungDesktop';
import { useAppSelector } from '../state/store';
import { monoFont, palette, tokens } from '../theme';

export interface SettingsScreenProps {
  onOpenDebug: () => void;
  onOpenSplitTunneling: () => void;
}

/**
 * iOS counterpart of Android's offline APK sharing: nothing to link natively — the TestFlight
 * invite link just goes to the system share sheet. Hidden until TESTFLIGHT_URL is configured.
 */
const isTestFlightShareAvailable =
  Platform.OS === 'ios' && AppConfig.TESTFLIGHT_URL.length > 0;

export function SettingsScreen({
  onOpenDebug,
  onOpenSplitTunneling,
}: SettingsScreenProps): React.JSX.Element {
  const s = useStrings();
  const { insets, twoColumns, contentWidth, columnWidth } = useTabSceneColumns();
  const columnStyle = { width: columnWidth };
  // Selectors, not the whole store: on iOS this scene stays mounted behind the other tabs, so
  // it must not re-render on every mirrored native event (log lines, recents).
  const isConnected = useAppSelector(current => current.native.status === 'connected');
  const update = useAppSelector(current => current.update);
  const splitTunnel = useAppSelector(current => current.splitTunnel);

  const onShareApk = useCallback(() => {
    shareInstalledApk(s.shareApkTitle).catch(error => {
      const message =
        apkShareErrorCode(error) === 'E_SPLIT_APK_INSTALL'
          ? s.shareApkSplitInstallError
          : s.shareApkErrorBody;
      Alert.alert(s.shareApkErrorTitle, message);
    });
  }, [s]);

  const onOpenUpdate = useCallback(() => {
    // Pinned destination only — never a manifest-supplied URL (see AppConfig.UPDATE_URL_ANDROID).
    const url = Platform.OS === 'ios' ? AppConfig.TESTFLIGHT_URL : AppConfig.UPDATE_URL_ANDROID;
    Linking.openURL(url).catch(() => {
      // Best-effort: ignore devices without a browser handler.
    });
  }, []);

  const onShareTestFlight = useCallback(() => {
    Share.share(
      { message: s.shareTestFlightMessage, url: AppConfig.TESTFLIGHT_URL },
      { subject: s.shareTestFlightTitle },
    ).catch(() => {
      Alert.alert(s.shareTestFlightErrorTitle, s.shareTestFlightErrorBody);
    });
  }, [s]);

  const onOpenSpeedTest = useCallback(() => {
    Linking.openURL(AppConfig.SPEED_TEST_URL).catch(() => {
      // Best-effort: ignore devices without a browser handler.
    });
  }, []);

  return (
    <ScrollView style={styles.root} contentContainerStyle={edgePadding(insets, 24)}>
      <View style={[styles.content, { width: contentWidth }]}>
        <Text style={styles.title}>{s.settingsTitle}</Text>

        <View style={[styles.sections, twoColumns && layout.twoColumns]}>
          <View style={[styles.sectionColumn, columnStyle]}>
            <Text style={styles.sectionHeader}>{s.settingsGeneralHeader.toUpperCase()}</Text>
            {update.tier !== 'none' && update.latestVersion != null ? (
              // Passive update row: present at every tier above 'none' — for 'available' (routine
              // releases, and the ceiling for unsigned manifests) it is the ONLY update UI.
              <SettingPanel
                title={s.updateSettingTitle}
                subtitle={s.updateSettingSubtitle(APP_VERSION, update.latestVersion)}
                onPress={onOpenUpdate}
              />
            ) : null}
            <SettingPanel
              title={s.languageSettingTitle}
              subtitle={s.languageSettingSubtitle}
              trailing={<LanguagePicker />}
            />
            <SettingPanel
              title={s.splitTunnelSettingTitle}
              subtitle={
                splitTunnel.enabled
                  ? s.splitTunnelSettingSubtitleOn
                  : s.splitTunnelSettingSubtitleOff
              }
              onPress={onOpenSplitTunneling}
            />
            {isApkShareAvailable ? (
              <SettingPanel
                title={s.shareApkTitle}
                subtitle={s.shareApkSubtitle}
                onPress={onShareApk}
              />
            ) : null}
            {isTestFlightShareAvailable ? (
              <SettingPanel
                title={s.shareTestFlightTitle}
                subtitle={s.shareTestFlightSubtitle}
                onPress={onShareTestFlight}
              />
            ) : null}
            {OpenRungDesktop != null ? (
              <>
                <Text style={styles.sectionHeader}>{s.desktopProxyHeader.toUpperCase()}</Text>
                <DesktopProxySection desktop={OpenRungDesktop} isConnected={isConnected} />
              </>
            ) : null}
          </View>
          <View style={[styles.sectionColumn, columnStyle]}>
            <Text style={styles.sectionHeader}>{s.settingsDiagnosticsHeader.toUpperCase()}</Text>
            <SettingPanel
              title={s.speedTestSettingTitle}
              subtitle={
                isConnected ? s.speedTestSettingSubtitle : s.speedTestRequiresConnection
              }
              onPress={onOpenSpeedTest}
              disabled={!isConnected}
            />
            <SettingPanel
              title={s.debugSettingTitle}
              subtitle={s.debugSettingSubtitle}
              onPress={onOpenDebug}
            />
          </View>
        </View>
      </View>
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
    gap: 14,
    alignSelf: 'center',
  },
  sections: {
    gap: 14,
  },
  sectionColumn: {
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
