/**
 * Green pill action button used as the trailing element of diagnostic rows
 * (speed test, exit IP check). Extracted from the original Settings speed-test
 * row; Material3 filled-button metrics (40dp pill, 24dp horizontal padding)
 * with M3 default disabled colors, as in production.
 */
import React from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';

import { monoFont, palette } from '../theme';

export interface RunButtonProps {
  label: string;
  onPress: () => void;
  enabled: boolean;
}

export function RunButton({ label, onPress, enabled }: RunButtonProps): React.JSX.Element {
  return (
    <Pressable
      onPress={onPress}
      disabled={!enabled}
      style={[styles.button, !enabled && styles.buttonDisabled]}
      accessibilityRole="button"
    >
      <Text style={[styles.label, !enabled && styles.labelDisabled]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    height: 40,
    borderRadius: 20,
    paddingHorizontal: 24,
    backgroundColor: palette.terminalGreen,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonDisabled: {
    backgroundColor: 'rgba(29, 27, 32, 0.12)',
  },
  label: {
    color: palette.onGreenText,
    fontFamily: monoFont,
    fontSize: 14,
    fontWeight: 'bold',
  },
  labelDisabled: {
    color: 'rgba(29, 27, 32, 0.38)',
  },
});
