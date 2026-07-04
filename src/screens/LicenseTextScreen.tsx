/**
 * Full license texts screen. 1:1 port of the production
 * OpenRungLicenseTextScreen: header + one scrollable column rendering the
 * bundled notices (component summary first, complete GNU GPL-3.0 text at the
 * end — the same order as the production res/raw/third_party_notices.txt) in
 * 11sp mono with 16sp line height.
 */
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ScreenHeader } from '../components/ScreenHeader';
import { useStrings } from '../i18n';
import { GPL_TEXT, THIRD_PARTY_TEXT } from '../licenses/notices';
import { monoFont, palette } from '../theme';

export interface LicenseTextScreenProps {
  onBack: () => void;
}

export function LicenseTextScreen({ onBack }: LicenseTextScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();

  return (
    <View
      style={[
        styles.root,
        { paddingTop: insets.top + 20, paddingBottom: insets.bottom + 20 },
      ]}
    >
      <ScreenHeader title={s.licensesFullTextTitle} onBack={onBack} />

      <ScrollView style={styles.scroll}>
        <Text style={styles.text}>{THIRD_PARTY_TEXT}</Text>
        <Text style={styles.text}>{GPL_TEXT}</Text>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
    paddingHorizontal: 20,
    gap: 16,
  },
  scroll: {
    flex: 1,
  },
  text: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 11,
    lineHeight: 16,
  },
});
