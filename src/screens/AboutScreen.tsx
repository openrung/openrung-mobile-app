/**
 * About us tab: wordmark hero with version pill, mission paragraph, a
 * numbered "how it works" walkthrough (relay operators -> broker -> encrypted
 * tunnel), then source-code / open-source-licenses panels and the GPL
 * footnote. Version and licensing moved here from Settings so the Settings
 * tab stays purely operational.
 */
import React, { useCallback } from 'react';
import { Linking, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SettingPanel } from '../components/SettingPanel';
import { APP_VERSION, AppConfig } from '../config';
import { useStrings, type Strings } from '../i18n';
import { monoFont, palette, tokens } from '../theme';

export interface AboutScreenProps {
  onOpenLicenses: () => void;
}

interface HowStep {
  title: (s: Strings) => string;
  body: (s: Strings) => string;
}

const HOW_STEPS: HowStep[] = [
  { title: s => s.aboutHow1Title, body: s => s.aboutHow1Body },
  { title: s => s.aboutHow2Title, body: s => s.aboutHow2Body },
  { title: s => s.aboutHow3Title, body: s => s.aboutHow3Body },
];

export function AboutScreen({ onOpenLicenses }: AboutScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();

  const onOpenSource = useCallback(() => {
    Linking.openURL(AppConfig.SOURCE_URL).catch(() => {
      // Ignore: no browser available.
    });
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
      <Text style={styles.title}>{s.aboutTitle}</Text>

      <View style={styles.hero}>
        <View style={styles.heroRow}>
          <Text style={styles.heroWordmark}>{s.appName}</Text>
          <View style={styles.versionPill}>
            <Text style={styles.versionText}>v{APP_VERSION}</Text>
          </View>
        </View>
        <Text style={styles.heroTagline}>{s.homeTagline}</Text>
        <Text style={styles.mission}>{s.aboutMissionBody}</Text>
      </View>

      <Text style={styles.sectionHeader}>{s.aboutHowHeader.toUpperCase()}</Text>
      <View style={styles.steps}>
        {HOW_STEPS.map((step, index) => (
          <View key={index} style={styles.step}>
            <Text style={styles.stepIndex}>{String(index + 1).padStart(2, '0')}</Text>
            <View style={styles.stepText}>
              <Text style={styles.stepTitle}>{step.title(s)}</Text>
              <Text style={styles.stepBody}>{step.body(s)}</Text>
            </View>
          </View>
        ))}
      </View>

      <Text style={styles.sectionHeader}>{s.aboutProjectHeader.toUpperCase()}</Text>
      <SettingPanel
        title={s.licensesSourceTitle}
        subtitle={AppConfig.SOURCE_URL}
        onPress={onOpenSource}
      />
      <SettingPanel
        title={s.licensesSettingTitle}
        subtitle={s.licensesSettingSubtitle}
        onPress={onOpenLicenses}
      />

      <Text style={styles.footnote}>{s.aboutFootnote}</Text>
    </ScrollView>
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
  hero: {
    borderRadius: tokens.radiusLg,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    padding: 18,
    gap: 6,
  },
  heroRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  heroWordmark: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 22,
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 10,
  },
  versionPill: {
    borderRadius: 999,
    borderWidth: 1,
    borderColor: palette.borderDim,
    backgroundColor: palette.fabBackground,
    paddingHorizontal: 10,
    paddingVertical: 3,
  },
  versionText: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 11,
  },
  heroTagline: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    letterSpacing: 1.2,
  },
  mission: {
    marginTop: 8,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 13,
    lineHeight: 20,
  },
  sectionHeader: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 11,
    letterSpacing: 1.5,
    marginTop: 8,
  },
  steps: {
    gap: 10,
  },
  step: {
    flexDirection: 'row',
    gap: 14,
    borderRadius: tokens.radiusMd,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    padding: 16,
  },
  stepIndex: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 16,
  },
  stepText: {
    flex: 1,
    gap: 4,
  },
  stepTitle: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 13,
  },
  stepBody: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 12,
    lineHeight: 18,
  },
  footnote: {
    marginTop: 6,
    textAlign: 'center',
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    lineHeight: 17,
  },
});
