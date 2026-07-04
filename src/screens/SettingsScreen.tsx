/**
 * Settings tab. Large title (it's a root tab now — no back arrow), then
 * sectioned panels: GENERAL (language) and DIAGNOSTICS (volunteer speed test,
 * debug console). Version and licenses live on the About tab. The language
 * picker mirrors the production dropdown semantics with a dark-styled modal
 * list; the speed test RUN button is enabled only while connected and not
 * already running.
 */
import React, { useCallback, useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SettingPanel } from '../components/SettingPanel';
import { AppConfig } from '../config';
import { languageOptions, useLanguage, useStrings } from '../i18n';
import { OpenRungVpn } from '../native/OpenRungVpn';
import { runSpeedTest, type SpeedTestResult } from '../net/speedTestClient';
import {
  buildSpeedTestCompletedEvent,
  buildSpeedTestFailedEvent,
  sendTelemetry,
} from '../net/telemetryClient';
import { useVpnState } from '../state/useVpnState';
import { monoFont, palette, tokens } from '../theme';

export interface SettingsScreenProps {
  onOpenDebug: () => void;
}

export function SettingsScreen({ onOpenDebug }: SettingsScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { isConnected } = useVpnState();

  const [speedTestRunning, setSpeedTestRunning] = useState(false);
  const [speedTestResult, setSpeedTestResult] = useState<SpeedTestResult | null>(null);
  const [speedTestError, setSpeedTestError] = useState<string | null>(null);

  // Same precedence as production: running > error > result > requires-connection > ready.
  const speedTestSubtitle = speedTestRunning
    ? s.speedTestRunning
    : speedTestError != null
      ? s.speedTestError(speedTestError)
      : speedTestResult != null
        ? s.speedTestResult(speedTestResult.downloadMbps)
        : !isConnected
          ? s.speedTestRequiresConnection
          : s.speedTestReady;

  const runEnabled = isConnected && !speedTestRunning;

  const onRunSpeedTest = useCallback(() => {
    setSpeedTestRunning(true);
    setSpeedTestResult(null);
    setSpeedTestError(null);
    (async () => {
      try {
        const result = await runSpeedTest(AppConfig.TELEMETRY_BROKER_URL);
        setSpeedTestResult(result);
        try {
          const identity = await OpenRungVpn.getIdentity();
          if (identity.sessionId != null) {
            // Telemetry is skipped when no session is active (contract §4).
            await sendTelemetry(AppConfig.TELEMETRY_BROKER_URL, [
              buildSpeedTestCompletedEvent(identity, result),
            ]);
          }
        } catch {
          // Telemetry is best-effort; never surfaces in the UI.
        }
      } catch (error) {
        // Mirrors production: message ?: exception simple name for the subtitle,
        // the error type name for the telemetry attribute.
        const errorType = error instanceof Error ? error.constructor.name || error.name : 'Error';
        const message = error instanceof Error ? error.message || errorType : String(error);
        setSpeedTestError(message);
        try {
          const identity = await OpenRungVpn.getIdentity();
          if (identity.sessionId != null) {
            await sendTelemetry(AppConfig.TELEMETRY_BROKER_URL, [
              buildSpeedTestFailedEvent(identity, errorType),
            ]);
          }
        } catch {
          // Best-effort.
        }
      } finally {
        setSpeedTestRunning(false);
      }
    })();
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

      <Text style={styles.sectionHeader}>{s.settingsDiagnosticsHeader.toUpperCase()}</Text>
      <SettingPanel
        title={s.speedTestSettingTitle}
        subtitle={speedTestSubtitle}
        trailing={
          <Pressable
            onPress={onRunSpeedTest}
            disabled={!runEnabled}
            style={[styles.runButton, !runEnabled && styles.runButtonDisabled]}
            accessibilityRole="button"
          >
            <Text style={[styles.runLabel, !runEnabled && styles.runLabelDisabled]}>
              {s.speedTestAction}
            </Text>
          </Pressable>
        }
      />
      <SettingPanel
        title={s.debugSettingTitle}
        subtitle={s.debugSettingSubtitle}
        onPress={onOpenDebug}
      />
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
  // Material3 filled button metrics: 40dp tall pill, 24dp horizontal padding.
  runButton: {
    height: 40,
    borderRadius: 20,
    paddingHorizontal: 24,
    backgroundColor: palette.terminalGreen,
    alignItems: 'center',
    justifyContent: 'center',
  },
  // Material3 default disabled colors (onSurface @ 12% / 38%), as in production.
  runButtonDisabled: {
    backgroundColor: 'rgba(29, 27, 32, 0.12)',
  },
  runLabel: {
    color: palette.onGreenText,
    fontFamily: monoFont,
    fontSize: 14,
    fontWeight: 'bold',
  },
  runLabelDisabled: {
    color: 'rgba(29, 27, 32, 0.38)',
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
