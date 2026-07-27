/**
 * "Recents" strip on the home screen: a small uppercase section label and a
 * horizontal row of compact glass pills (flag + relay name) floating
 * over the map. Hidden entirely while there is no history, so a fresh install
 * keeps the map uncluttered.
 *
 * Tapping a pill pins the exact relay that produced that recent entry.
 */
import React from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import type { RecentNode } from '../native/types';
import { monoFont, palette, tokens } from '../theme';
import { countryFlag } from './countryFlag';

export interface RecentsSectionProps {
  recents: RecentNode[];
  onPress: (relayId: string, countryCode: string) => void;
}

interface PinnedRecentNode extends RecentNode {
  relayId: string;
  relayName: string;
}

function hasPinnedRelay(node: RecentNode): node is PinnedRecentNode {
  return (node.relayId?.trim().length ?? 0) > 0 && (node.relayName?.trim().length ?? 0) > 0;
}

export function RecentsSection({ recents, onPress }: RecentsSectionProps): React.JSX.Element | null {
  const s = useStrings();
  // Legacy entries cannot pin the relay they describe, so keep them hidden until a successful
  // connection replaces them with an entry containing both relayId and relayName.
  const pinnedRecents = recents.filter(hasPinnedRelay);

  if (pinnedRecents.length === 0) {
    return null;
  }

  return (
    <View style={styles.column}>
      <Text style={styles.label}>{s.recentsLabel.toUpperCase()}</Text>
      <FlatList
        horizontal
        data={pinnedRecents}
        keyExtractor={item => item.relayId}
        renderItem={({ item }) => (
          <Pressable
            accessibilityRole="button"
            style={({ pressed }) => [styles.pill, pressed && styles.pillPressed]}
            onPress={() => onPress(item.relayId, item.countryCode)}
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
