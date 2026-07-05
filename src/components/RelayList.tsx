/**
 * List presentation of the exit-node directory: the same broker-served
 * regions the map shows, as a scrollable glass panel of tappable rows
 * (flag + "City, Country" + relay count), sorted by country then city so
 * neighbouring exits group together.
 *
 * Every location row expands on tap into one indented child row per volunteer
 * relay, shown by its volunteer-chosen label ("silly-lemur"); tapping a child
 * connects to that specific relay. (The map markers keep the broker-picks
 * country flow; the list is the precise picker.)
 *
 * While the directory is empty the panel mirrors the status chip's states:
 * loading, failed (tap to retry), and loaded-but-empty (tap to retry) each
 * render as a single centered status line.
 */
import React, { useMemo, useState } from 'react';
import { FlatList, Pressable, StyleSheet, StyleProp, Text, View, ViewStyle } from 'react-native';

import { useStrings } from '../i18n';
import type { DirectoryStatus, ExitNodeRegion, ExitNodeRelay } from '../model/exitNode';
import { monoFont, palette, tokens } from '../theme';
import { countryFlag } from './countryFlag';

export interface RelayListProps {
  regions: ExitNodeRegion[];
  directoryStatus: DirectoryStatus;
  /** Connect to one specific volunteer relay (picked from an expanded location). */
  onRelayPress: (relayId: string, countryCode: string) => void;
  onRetry: () => void;
  style?: StyleProp<ViewStyle>;
}

type Row =
  | { kind: 'region'; key: string; region: ExitNodeRegion }
  | { kind: 'relay'; key: string; relay: ExitNodeRelay; countryCode: string };

function regionKey(region: ExitNodeRegion): string {
  return `${region.countryCode}|${region.city ?? ''}`;
}

/** Display name for a relay child row; volunteer label, or the bare broker id as fallback. */
function relayLabel(relay: ExitNodeRelay): string {
  return relay.label ?? relay.id.replace(/^relay_/, '').slice(0, 12);
}

export function RelayList({
  regions,
  directoryStatus,
  onRelayPress,
  onRetry,
  style,
}: RelayListProps): React.JSX.Element {
  const s = useStrings();
  const [expandedKeys, setExpandedKeys] = useState<ReadonlySet<string>>(new Set());

  const rows = useMemo<Row[]>(() => {
    const sorted = [...regions].sort(
      (a, b) =>
        a.countryName.localeCompare(b.countryName) ||
        (a.city ?? '').localeCompare(b.city ?? ''),
    );
    const flattened: Row[] = [];
    for (const region of sorted) {
      const key = regionKey(region);
      flattened.push({ kind: 'region', key, region });
      if (expandedKeys.has(key)) {
        for (const relay of region.relays) {
          flattened.push({
            kind: 'relay',
            key: `${key}#${relay.id}`,
            relay,
            countryCode: region.countryCode,
          });
        }
      }
    }
    return flattened;
  }, [regions, expandedKeys]);

  if (rows.length === 0) {
    const isFailed = directoryStatus === 'failed';
    const text =
      isFailed ? s.mapFailed : directoryStatus === 'loaded' ? s.mapNoNodes : s.mapLoading;
    const canRetry = isFailed || directoryStatus === 'loaded';
    const label = (
      <Text style={[styles.statusText, isFailed && styles.statusTextFailed]}>{text}</Text>
    );
    return (
      <View style={[styles.panel, styles.statusPanel, style]}>
        {canRetry ? (
          <Pressable onPress={onRetry} accessibilityRole="button">
            {label}
          </Pressable>
        ) : (
          label
        )}
      </View>
    );
  }

  const toggleExpanded = (key: string) => {
    setExpandedKeys(current => {
      const next = new Set(current);
      if (!next.delete(key)) {
        next.add(key);
      }
      return next;
    });
  };

  return (
    <View style={[styles.panel, style]}>
      <FlatList
        data={rows}
        keyExtractor={row => row.key}
        accessibilityLabel={s.listContentDescription}
        renderItem={({ item }) => {
          if (item.kind === 'relay') {
            return (
              <Pressable
                style={({ pressed }) => [styles.relayRow, pressed && styles.rowPressed]}
                onPress={() => onRelayPress(item.relay.id, item.countryCode)}
                accessibilityRole="button"
                accessibilityLabel={relayLabel(item.relay)}
              >
                <Text style={styles.relayBullet}>└</Text>
                <Text style={styles.relayLabel} numberOfLines={1}>
                  {relayLabel(item.relay)}
                </Text>
              </Pressable>
            );
          }
          const { region } = item;
          const expanded = expandedKeys.has(item.key);
          return (
            <Pressable
              style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}
              onPress={() => toggleExpanded(item.key)}
              accessibilityRole="button"
              accessibilityState={{ expanded }}
            >
              <Text style={styles.flag}>{countryFlag(region.countryCode)}</Text>
              <Text style={styles.rowLabel} numberOfLines={1}>
                {region.city ? `${region.city}, ${region.countryName}` : region.countryName}
              </Text>
              <Text style={styles.rowCount}>{s.listRelayCount(region.nodeCount)}</Text>
              <Text style={styles.chevron}>{expanded ? '▾' : '▸'}</Text>
            </Pressable>
          );
        }}
        ItemSeparatorComponent={RowDivider}
        showsVerticalScrollIndicator={false}
      />
    </View>
  );
}

function RowDivider(): React.JSX.Element {
  return <View style={styles.divider} />;
}

const styles = StyleSheet.create({
  panel: {
    borderRadius: tokens.radiusLg,
    backgroundColor: tokens.glass,
    borderWidth: 1,
    borderColor: tokens.glassBorder,
    overflow: 'hidden',
  },
  statusPanel: {
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  statusText: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 12,
    textAlign: 'center',
  },
  statusTextFailed: {
    color: palette.chipFailedText,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingHorizontal: 16,
    paddingVertical: 13,
  },
  relayRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 11,
    paddingRight: 16,
    // Children indent to sit under the parent's label (past the flag column).
    paddingLeft: 42,
  },
  rowPressed: {
    opacity: 0.6,
  },
  flag: {
    fontSize: 16,
  },
  rowLabel: {
    flex: 1,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 13,
  },
  rowCount: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 11,
  },
  chevron: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 12,
  },
  relayBullet: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 12,
  },
  relayLabel: {
    flex: 1,
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 13,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: palette.borderDim,
    opacity: 0.55,
    marginLeft: 42,
  },
});
