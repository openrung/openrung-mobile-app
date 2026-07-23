import React from 'react';
import { Pressable, StyleSheet, Text, View, type StyleProp, type ViewStyle } from 'react-native';

import { monoFont, palette, tokens } from '../theme';

/**
 * Dismissible glass card for the home-screen overlay: the "update available" banner (notify tier)
 * and operator broadcast notices both render through this. Purely presentational — the caller
 * supplies already-localized text and the actions.
 */
export interface UpdateBannerProps {
  title: string;
  body: string;
  /** 'warn' switches the title/accents to the working-yellow tone. Default 'info' (green). */
  level?: 'info' | 'warn';
  /** Optional primary action ("UPDATE", "Learn more"); hidden when label is absent. */
  primaryLabel?: string;
  onPrimary?: () => void;
  dismissLabel: string;
  onDismiss: () => void;
  style?: StyleProp<ViewStyle>;
}

export function UpdateBanner({
  title,
  body,
  level = 'info',
  primaryLabel,
  onPrimary,
  dismissLabel,
  onDismiss,
  style,
}: UpdateBannerProps): React.JSX.Element {
  const accent = level === 'warn' ? tokens.working : palette.terminalGreen;
  return (
    <View style={[styles.card, level === 'warn' && styles.cardWarn, style]}>
      <Text style={[styles.title, { color: accent }]}>{title}</Text>
      <Text style={styles.body}>{body}</Text>
      <View style={styles.actions}>
        {primaryLabel != null && onPrimary != null ? (
          <Pressable
            onPress={onPrimary}
            style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}
            accessibilityRole="button"
          >
            <Text style={styles.primaryLabel}>{primaryLabel}</Text>
          </Pressable>
        ) : null}
        <Pressable
          onPress={onDismiss}
          style={({ pressed }) => [styles.dismissButton, pressed && styles.pressed]}
          accessibilityRole="button"
        >
          <Text style={styles.dismissLabel}>{dismissLabel}</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: tokens.radiusMd,
    backgroundColor: tokens.glass,
    borderWidth: 1,
    borderColor: tokens.glassBorder,
    padding: 14,
    gap: 8,
  },
  cardWarn: {
    borderColor: tokens.working,
  },
  title: {
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
  },
  body: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 13,
    lineHeight: 18,
  },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 18,
    marginTop: 2,
  },
  primaryButton: {
    height: 36,
    borderRadius: 18,
    paddingHorizontal: 18,
    backgroundColor: palette.terminalGreen,
    alignItems: 'center',
    justifyContent: 'center',
  },
  primaryLabel: {
    color: palette.onGreenText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 13,
  },
  dismissButton: {
    paddingVertical: 8,
  },
  dismissLabel: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 13,
  },
  pressed: {
    opacity: 0.85,
  },
});
