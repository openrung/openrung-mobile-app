/**
 * "Recents" strip on the home screen: a small uppercase section label and a
 * horizontal row of compact glass pills (flag + recorded location) floating
 * over the map. Hidden entirely while there is no history, so a fresh install
 * keeps the map uncluttered.
 *
 * Pills are tappable: tapping reconnects to that location (the broker still
 * picks the concrete relay there), and the trailing star adds/removes it from
 * the Favorites strip. (Earlier versions were display-only; that decision was
 * reversed when favorites landed.)
 */
import React from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import type { RecentNode } from '../native/types';
import { monoFont, palette } from '../theme';
import { LocationPill } from './LocationPill';

export interface RecentsSectionProps {
  recents: RecentNode[];
  favorites: string[];
  onSelect: (countryCode: string) => void;
  onToggleFavorite: (countryCode: string) => void;
}

export function RecentsSection({
  recents,
  favorites,
  onSelect,
  onToggleFavorite,
}: RecentsSectionProps): React.JSX.Element | null {
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
          <LocationPill
            countryCode={item.countryCode}
            label={item.label}
            onPress={() => onSelect(item.countryCode)}
            starred={favorites.includes(item.countryCode)}
            onToggleStar={() => onToggleFavorite(item.countryCode)}
          />
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
  gap: {
    width: 8,
  },
});
