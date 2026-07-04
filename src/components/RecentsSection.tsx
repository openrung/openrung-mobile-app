/**
 * "Recents" strip on the home screen: a small uppercase section label and a
 * horizontal row of compact glass pills (flag + recorded location) floating
 * over the map. Hidden entirely while there is no history, so a fresh install
 * keeps the map uncluttered.
 *
 * Pills are deliberately NOT tappable: recents are recorded from past
 * connections (the broker picks the relay), not a connect affordance.
 */
import React from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import type { RecentNode } from '../native/types';
import { monoFont, palette, tokens } from '../theme';

export interface RecentsSectionProps {
  recents: RecentNode[];
}

/** ISO 3166-1 alpha-2 -> flag emoji via regional indicators; neutral flag if invalid. */
function countryFlag(code: string): string {
  const upper = code.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(upper)) {
    return '🏳';
  }
  const first = 0x1f1e6 + (upper.charCodeAt(0) - 65);
  const second = 0x1f1e6 + (upper.charCodeAt(1) - 65);
  return String.fromCodePoint(first) + String.fromCodePoint(second);
}

export function RecentsSection({ recents }: RecentsSectionProps): React.JSX.Element | null {
  const s = useStrings();

  if (recents.length === 0) {
    return null;
  }

  return (
    <View style={styles.column}>
      <Text style={styles.label}>{s.recentsLabel.toUpperCase()}</Text>
      <FlatList
        horizontal
        data={recents}
        keyExtractor={item => item.countryCode}
        renderItem={({ item }) => (
          <View style={styles.pill}>
            <Text style={styles.flag}>{countryFlag(item.countryCode)}</Text>
            <Text style={styles.pillLabel} numberOfLines={1}>
              {item.label}
            </Text>
          </View>
        )}
        ItemSeparatorComponent={PillGap}
        showsHorizontalScrollIndicator={false}
      />
    </View>
  );
}

function PillGap(): React.JSX.Element {
  return <View style={styles.gap} />;
}

const styles = StyleSheet.create({
  column: {
    gap: 8,
  },
  label: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 10,
    letterSpacing: 1.5,
  },
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
  pillLabel: {
    flexShrink: 1,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 12,
  },
  flag: {
    fontSize: 16,
  },
  gap: {
    width: 8,
  },
});
