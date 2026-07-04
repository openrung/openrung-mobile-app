/**
 * Shared sub-screen header: back arrow + 8dp spacer + bold 22sp title.
 * Mirrors the header row used by every non-MAIN screen in the production
 * Android app (IconButton with AutoMirrored ArrowBack, terminal-green tint).
 */
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import { monoFont, palette } from '../theme';

export interface ScreenHeaderProps {
  title: string;
  onBack: () => void;
}

export function ScreenHeader({ title, onBack }: ScreenHeaderProps): React.JSX.Element {
  const s = useStrings();
  return (
    <View style={styles.row}>
      <Pressable
        onPress={onBack}
        style={styles.backButton}
        accessibilityRole="button"
        accessibilityLabel={s.backContentDescription}
        hitSlop={4}
      >
        <Text style={styles.backIcon}>←</Text>
      </Pressable>
      <View style={styles.spacer} />
      <Text style={styles.title}>{title}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  // Production uses a 48dp Material IconButton.
  backButton: {
    width: 48,
    height: 48,
    alignItems: 'center',
    justifyContent: 'center',
  },
  backIcon: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 22,
  },
  spacer: {
    width: 8,
  },
  title: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 22,
  },
});
