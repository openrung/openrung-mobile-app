/**
 * Open-source licenses screen. 1:1 port of the production
 * OpenRungLicensesScreen: GPL intro paragraph, "Source code" panel (opens the
 * public repository), "Full license texts" panel (opens the full-text
 * screen), then the "Components" header and the per-component license
 * panels from the bundled notices.
 */
import React, { useCallback } from 'react';
import { Linking, ScrollView, StyleSheet, Text } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ScreenHeader } from '../components/ScreenHeader';
import { SettingPanel } from '../components/SettingPanel';
import { AppConfig } from '../config';
import { useStrings } from '../i18n';
import { components } from '../licenses/notices';
import { monoFont, palette } from '../theme';

export interface LicensesScreenProps {
  onBack: () => void;
  onOpenFullText: () => void;
}

export function LicensesScreen({
  onBack,
  onOpenFullText,
}: LicensesScreenProps): React.JSX.Element {
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
        { paddingTop: insets.top + 20, paddingBottom: insets.bottom + 20 },
      ]}
    >
      <ScreenHeader title={s.licensesTitle} onBack={onBack} />

      <Text style={styles.intro}>{s.licensesIntro}</Text>

      <SettingPanel
        title={s.licensesSourceTitle}
        subtitle={AppConfig.SOURCE_URL}
        onPress={onOpenSource}
      />

      <SettingPanel
        title={s.licensesFullTextTitle}
        subtitle={s.licensesFullTextSubtitle}
        onPress={onOpenFullText}
      />

      <Text style={styles.componentsHeader}>{s.licensesComponentsHeader}</Text>

      {components.map(entry => (
        <SettingPanel key={entry.name} title={entry.name} subtitle={entry.license} />
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
  },
  content: {
    paddingHorizontal: 20,
    gap: 16,
  },
  intro: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 13,
    lineHeight: 19,
  },
  componentsHeader: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
    marginTop: 4,
  },
});
