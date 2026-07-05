/**
 * RN Switch themed for the terminal palette, used as the trailing element of
 * settings rows (auto-connect, remember last exit). Keeps the platform switch
 * behavior; only the colors are branded.
 */
import React from 'react';
import { Switch } from 'react-native';

import { palette, tokens } from '../theme';

export interface ToggleSwitchProps {
  value: boolean;
  onValueChange: (value: boolean) => void;
  accessibilityLabel?: string;
}

export function ToggleSwitch({
  value,
  onValueChange,
  accessibilityLabel,
}: ToggleSwitchProps): React.JSX.Element {
  return (
    <Switch
      value={value}
      onValueChange={onValueChange}
      trackColor={{ false: palette.fabBackground, true: tokens.glowSoft }}
      thumbColor={value ? palette.terminalGreen : palette.dimText}
      ios_backgroundColor={palette.fabBackground}
      accessibilityLabel={accessibilityLabel}
    />
  );
}
