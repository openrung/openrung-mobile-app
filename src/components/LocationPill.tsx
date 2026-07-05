/**
 * Compact glass pill for a location (flag + label), shared by the Recents and
 * Favorites strips on the home screen. Tapping the pill connects to that
 * location; the trailing star toggles it as a favorite. Extracted from
 * RecentsSection when recents became tappable.
 */
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import { monoFont, palette, tokens } from '../theme';
import { StarIcon } from './Icons';

export interface LocationPillProps {
  countryCode: string;
  label: string;
  onPress?: () => void;
  starred?: boolean;
  onToggleStar?: () => void;
}

/** ISO 3166-1 alpha-2 -> flag emoji via regional indicators; neutral flag if invalid. */
export function countryFlag(code: string): string {
  const upper = code.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(upper)) {
    return '🏳';
  }
  const first = 0x1f1e6 + (upper.charCodeAt(0) - 65);
  const second = 0x1f1e6 + (upper.charCodeAt(1) - 65);
  return String.fromCodePoint(first) + String.fromCodePoint(second);
}

export function LocationPill({
  countryCode,
  label,
  onPress,
  starred = false,
  onToggleStar,
}: LocationPillProps): React.JSX.Element {
  const s = useStrings();

  const inner = (
    <>
      <Text style={styles.flag}>{countryFlag(countryCode)}</Text>
      <Text style={styles.pillLabel} numberOfLines={1}>
        {label}
      </Text>
      {onToggleStar != null ? (
        <Pressable
          onPress={onToggleStar}
          hitSlop={10}
          accessibilityRole="button"
          accessibilityLabel={
            starred ? s.favoriteRemoveContentDescription : s.favoriteAddContentDescription
          }
        >
          <StarIcon
            color={starred ? palette.terminalGreen : palette.dimText}
            size={15}
            strokeWidth={1.6}
            filled={starred}
          />
        </Pressable>
      ) : null}
    </>
  );

  if (onPress != null) {
    return (
      <Pressable
        onPress={onPress}
        style={({ pressed }) => [styles.pill, pressed && styles.pillPressed]}
        accessibilityRole="button"
        accessibilityLabel={s.locationConnectContentDescription(label)}
      >
        {inner}
      </Pressable>
    );
  }
  return <View style={styles.pill}>{inner}</View>;
}

const styles = StyleSheet.create({
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    maxWidth: 200,
    borderRadius: tokens.radiusSm,
    backgroundColor: tokens.glass,
    borderWidth: 1,
    borderColor: tokens.glassBorder,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  pillPressed: {
    opacity: 0.8,
  },
  pillLabel: {
    flexShrink: 1,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 12,
  },
  flag: {
    fontSize: 16,
  },
});
