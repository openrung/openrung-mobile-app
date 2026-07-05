/**
 * "Favorites" strip on the home screen: starred exit locations as tappable
 * glass pills, shown above Recents. Tap = connect to that country; star tap =
 * unfavorite. Hidden entirely while nothing is starred, mirroring Recents.
 */
import React from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import { displayName } from '../model/countryGeo';
import { monoFont, palette } from '../theme';
import { LocationPill } from './LocationPill';

export interface FavoritesSectionProps {
  favorites: string[]; // ISO alpha-2 country codes
  onSelect: (countryCode: string) => void;
  onToggleFavorite: (countryCode: string) => void;
}

export function FavoritesSection({
  favorites,
  onSelect,
  onToggleFavorite,
}: FavoritesSectionProps): React.JSX.Element | null {
  const s = useStrings();

  if (favorites.length === 0) {
    return null;
  }

  return (
    <View style={styles.column}>
      <Text style={styles.label}>{s.favoritesLabel.toUpperCase()}</Text>
      <FlatList
        horizontal
        data={favorites}
        keyExtractor={code => code}
        renderItem={({ item }) => (
          <LocationPill
            countryCode={item}
            label={displayName(item) ?? item}
            onPress={() => onSelect(item)}
            starred
            onToggleStar={() => onToggleFavorite(item)}
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
