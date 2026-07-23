/**
 * Terminal-style ON/OFF switch: a compact mono pill that lights up
 * terminal-green over a soft green fill when on — the same active/inactive
 * language as ViewModeToggle's segments, shrunk to a single toggle so it can
 * trail a settings row.
 */
import React from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';

import { monoFont, palette, tokens } from '../theme';

export interface TerminalSwitchProps {
  value: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}

export function TerminalSwitch({
  value,
  onChange,
  disabled,
}: TerminalSwitchProps): React.JSX.Element {
  return (
    <Pressable
      onPress={() => onChange(!value)}
      disabled={disabled}
      style={[styles.pill, value && styles.pillActive, disabled && styles.pillDisabled]}
      accessibilityRole="switch"
      accessibilityState={{ checked: value, disabled: disabled === true }}
    >
      <Text style={[styles.label, value && styles.labelActive]}>{value ? 'ON' : 'OFF'}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  pill: {
    minWidth: 54,
    alignItems: 'center',
    borderRadius: tokens.radiusSm,
    backgroundColor: tokens.glass,
    borderWidth: 1,
    borderColor: tokens.glassBorder,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  pillActive: {
    backgroundColor: 'rgba(101, 245, 138, 0.12)',
  },
  pillDisabled: {
    opacity: 0.45,
  },
  label: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 10,
    letterSpacing: 1.5,
  },
  labelActive: {
    color: palette.terminalGreen,
    fontWeight: 'bold',
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 8,
  },
});
