/**
 * Tiny boxed relay-class label: "OFFICIAL" in terminal green for foundation
 * relays, "VOLUNTEER" in orange for volunteer relays. Rendered right-aligned in
 * the relay list's per-relay rows and in the connect card's status row while
 * connected. Text-only inside a 1px box, per the terminal UI language
 * (contract §5: monospace everywhere, state communicated by text).
 */
import React from 'react';
import { StyleProp, StyleSheet, Text, View, ViewStyle } from 'react-native';

import { resolveLanguage, useLanguage } from '../i18n';
import type { RelayNodeClass } from '../model/exitNode';
import { monoFont, palette, tokens } from '../theme';

export interface RelayClassBadgeProps {
  nodeClass: RelayNodeClass;
  style?: StyleProp<ViewStyle>;
}

export function RelayClassBadge({ nodeClass, style }: RelayClassBadgeProps): React.JSX.Element {
  const { strings, languageTag } = useLanguage();
  const official = nodeClass === 'foundation';
  const label = official ? strings.relayClassOfficial : strings.relayClassVolunteer;
  return (
    <View style={[styles.badge, official ? styles.badgeOfficial : styles.badgeVolunteer, style]}>
      {/* Locale-aware uppercasing (Turkish i -> İ, not I); screen readers get the
          natural-case word rather than the all-caps render form. */}
      <Text
        style={[styles.label, official ? styles.labelOfficial : styles.labelVolunteer]}
        accessibilityLabel={label}
      >
        {label.toLocaleUpperCase(resolveLanguage(languageTag))}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    borderWidth: 1,
    borderRadius: 4,
    paddingHorizontal: 6,
    paddingVertical: 2,
    alignSelf: 'center',
  },
  badgeOfficial: {
    borderColor: palette.terminalGreen,
    backgroundColor: 'rgba(101, 245, 138, 0.10)',
  },
  badgeVolunteer: {
    borderColor: tokens.volunteer,
    backgroundColor: 'rgba(245, 165, 101, 0.10)',
  },
  label: {
    fontFamily: monoFont,
    fontSize: 9,
    fontWeight: 'bold',
    letterSpacing: 1.2,
  },
  labelOfficial: {
    color: palette.terminalGreen,
  },
  labelVolunteer: {
    color: tokens.volunteer,
  },
});
