/**
 * "Recents" strip on the home screen: a small uppercase section label and a
 * horizontal row of compact glass pills (flag + relay name) floating
 * over the map. Hidden entirely while there is no history, so a fresh install
 * keeps the map uncluttered.
 *
 * Tapping a pill reconnects to that country, same flow as tapping a region
 * on the map (broker still picks the specific relay within it).
 */
import React from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import type { RecentNode } from '../native/types';
import { monoFont, palette, tokens } from '../theme';
import { countryFlag } from './countryFlag';

export interface RecentsSectionProps {
  recents: RecentNode[];
  onPress: (countryCode: string) => void;
}

interface NamedRecentNode extends RecentNode {
  relayName: string;
}

function hasRelayName(node: RecentNode): node is NamedRecentNode {
  return (node.relayName?.trim().length ?? 0) > 0;
}

export function RecentsSection({ recents, onPress }: RecentsSectionProps): React.JSX.Element | null {
  const s = useStrings();
  // Entries persisted by older app versions only contain a city/country label. Do not show that
  // stale location copy; each entry returns after its next successful connection with relayName.
  const namedRecents = recents.filter(hasRelayName);

  if (namedRecents.length === 0) {
    return null;
  }

  return (
    <View style={styles.column}>
      <Text style={styles.label}>{s.recentsLabel.toUpperCase()}</Text>
      <FlatList
        horizontal
        data={namedRecents}
        keyExtractor={item => item.countryCode}
        renderItem={({ item }) => (
          <Pressable
            style={({ pressed }) => [styles.pill, pressed && styles.pillPressed]}
            onPress={() => onPress(item.countryCode)}
          >
            <Text style={styles.flag}>{countryFlag(item.countryCode)}</Text>
            <Text style={styles.pillLabel} numberOfLines={1}>
              {item.relayName.trim()}
            </Text>
          </Pressable>
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
  pillPressed: {
    opacity: 0.6,
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
