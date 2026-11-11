/**
 * Shared settings/licenses row panel. Mirrors the production Compose
 * SettingPanel/LicensePanel: 8dp-rounded #07110B panel with a 1dp #294F35
 * border, 14dp padding, bold title + 13sp dim subtitle, and either a custom
 * trailing element or (when clickable) a terminal-green chevron. A disabled
 * clickable row stays in place, dimmed, and ignores presses.
 */
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import { monoFont, palette } from '../theme';

export interface SettingPanelProps {
  title: string;
  subtitle: string;
  onPress?: () => void;
  /** Only meaningful with `onPress`: dims the row and ignores presses. */
  disabled?: boolean;
  trailing?: React.ReactNode;
}

export function SettingPanel({
  title,
  subtitle,
  onPress,
  disabled = false,
  trailing,
}: SettingPanelProps): React.JSX.Element {
  const s = useStrings();

  const inner = (
    <>
      <View style={styles.textColumn}>
        <Text style={styles.title}>{title}</Text>
        <Text style={styles.subtitle}>{subtitle}</Text>
      </View>
      {trailing != null ? (
        <View style={styles.trailing}>{trailing}</View>
      ) : onPress != null ? (
        <Text style={styles.chevron} accessibilityLabel={s.openContentDescription}>
          ›
        </Text>
      ) : null}
    </>
  );

  if (onPress != null) {
    return (
      <Pressable
        onPress={onPress}
        disabled={disabled}
        style={({ pressed }) => [
          styles.row,
          pressed && styles.rowPressed,
          disabled && styles.rowDisabled,
        ]}
        accessibilityRole="button"
        accessibilityState={{ disabled }}
      >
        {inner}
      </Pressable>
    );
  }
  return <View style={styles.row}>{inner}</View>;
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderRadius: 8,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    padding: 14,
    overflow: 'hidden',
  },
  rowPressed: {
    opacity: 0.85,
  },
  rowDisabled: {
    opacity: 0.45,
  },
  textColumn: {
    flex: 1,
    gap: 4,
  },
  title: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
  },
  subtitle: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 13,
  },
  trailing: {
    marginLeft: 12,
  },
  chevron: {
    marginLeft: 12,
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 20,
  },
});
