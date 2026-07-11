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
 *
 * Once populated, a deliberate pull-down forces a broker re-fetch (the same
 * forced refresh as tap-to-retry); the spinner tracks the in-flight load. On
 * iOS the pull must pass a distance threshold before it engages — the native
 * RefreshControl triggers too eagerly, so an incidental drag while scrolling
 * the list would re-fetch. Android keeps the platform RefreshControl (it has
 * no rubber-band overscroll to measure, and its trigger distance is fine).
 */
import React, { useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  FlatList,
  Image,
  Platform,
  Pressable,
  RefreshControl,
  StyleSheet,
  StyleProp,
  Text,
  View,
  ViewStyle,
} from 'react-native';
import type { NativeScrollEvent, NativeSyntheticEvent } from 'react-native';

import { useStrings } from '../i18n';
import { relayDisplayName } from '../model/exitNode';
import type { DirectoryStatus, ExitNodeRegion, ExitNodeRelay } from '../model/exitNode';
import { monoFont, palette, tokens } from '../theme';
import { countryFlag } from './countryFlag';

/**
 * Overscroll distance (px) a pull must reach before it engages a refresh, set
 * well beyond the iOS default (~60–80px) so a deliberate tug is needed. iOS
 * only — Android uses its RefreshControl.
 */
const PULL_TO_REFRESH_THRESHOLD_PX = 120;

/**
 * Pull-to-refresh easter egg, shown (untranslated, every locale) while the
 * list is dragged: Sun Yat-sen's political testament — "The revolution has
 * not yet succeeded; comrades, you must carry on the effort." — as brush
 * calligraphy signed 孫文, tinted the terminal green at render time (the
 * PNG itself is monochrome-on-transparent). Deliberately NOT in the i18n
 * string tables: it's a wink to Chinese-reading users of an anti-censorship
 * tunnel, and it reads the same in every UI language.
 */
const PULL_QUOTE_IMAGE = require('../assets/pull-quote-calligraphy.png');
/** Plain-text rendering of the calligraphy, for assistive tech. */
const PULL_QUOTE_A11Y = '革命尚未成功，同志仍須努力 - 孫中山';

export interface RelayListProps {
  regions: ExitNodeRegion[];
  directoryStatus: DirectoryStatus;
  /** Connect to one specific volunteer relay (picked from an expanded location). */
  onRelayPress: (relayId: string, countryCode: string) => void;
  /** Forced broker re-fetch: tap-to-retry on the empty panel AND pull-to-refresh on the list. */
  onRetry: () => void;
  /** True while a directory load is in flight; keeps the pull-to-refresh spinner up. */
  refreshing?: boolean;
  style?: StyleProp<ViewStyle>;
}

type Row =
  | { kind: 'region'; key: string; region: ExitNodeRegion }
  | { kind: 'relay'; key: string; relay: ExitNodeRelay; countryCode: string };

function regionKey(region: ExitNodeRegion): string {
  return `${region.countryCode}|${region.city ?? ''}`;
}

export function RelayList({
  regions,
  directoryStatus,
  onRelayPress,
  onRetry,
  refreshing = false,
  style,
}: RelayListProps): React.JSX.Element {
  const s = useStrings();
  const [expandedKeys, setExpandedKeys] = useState<ReadonlySet<string>>(new Set());

  // iOS custom pull-to-refresh: track overscroll so the indicator can reveal as
  // the list is dragged and the release can be measured against the threshold.
  // `pulling` gates mounting the indicator so it costs nothing (and stays out of
  // the tree) at rest; setState from the scroll listener no-ops until the bool
  // actually flips, so it is not a per-frame render.
  const [pulling, setPulling] = useState(false);
  const scrollY = useRef(new Animated.Value(0)).current;
  const handleScroll = useMemo(
    () =>
      Animated.event([{ nativeEvent: { contentOffset: { y: scrollY } } }], {
        useNativeDriver: false,
        listener: (event: NativeSyntheticEvent<NativeScrollEvent>) => {
          setPulling(event.nativeEvent.contentOffset.y < -8);
        },
      }),
    [scrollY],
  );

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

  const isIOS = Platform.OS === 'ios';
  // The quote fades in over the pull, reaching full opacity exactly at the
  // threshold — fully legible reads as "release to refresh".
  const pullOpacity = scrollY.interpolate({
    inputRange: [-PULL_TO_REFRESH_THRESHOLD_PX, 0],
    outputRange: [1, 0],
    extrapolate: 'clamp',
  });
  // Fire the forced refresh only if the finger lifts while still past the
  // threshold (pulling back up before release cancels, like the native control).
  const onPullRelease = (event: NativeSyntheticEvent<NativeScrollEvent>) => {
    if (!refreshing && event.nativeEvent.contentOffset.y <= -PULL_TO_REFRESH_THRESHOLD_PX) {
      onRetry();
    }
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
                accessibilityLabel={relayDisplayName(item.relay)}
              >
                <Text style={styles.relayBullet}>└</Text>
                <Text style={styles.relayLabel} numberOfLines={1}>
                  {relayDisplayName(item.relay)}
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
        {...(isIOS
          ? {
              onScroll: handleScroll,
              scrollEventThrottle: 16,
              onScrollEndDrag: onPullRelease,
              // Hold the rows down under the spinner while the fetch is in flight,
              // mirroring how the native control parks the content.
              contentContainerStyle: refreshing ? styles.listContentRefreshing : undefined,
            }
          : {
              refreshControl: (
                <RefreshControl
                  refreshing={refreshing}
                  onRefresh={onRetry}
                  tintColor={palette.terminalGreen}
                  colors={[palette.terminalGreen]}
                  progressBackgroundColor={palette.screen}
                />
              ),
            })}
      />
      {isIOS && (pulling || refreshing) && (
        <Animated.View
          pointerEvents="none"
          style={[styles.pullIndicator, { opacity: refreshing ? 1 : pullOpacity }]}
        >
          {refreshing ? (
            <ActivityIndicator size="small" color={palette.terminalGreen} />
          ) : (
            <Image
              source={PULL_QUOTE_IMAGE}
              style={styles.pullQuote}
              resizeMode="contain"
              accessibilityLabel={PULL_QUOTE_A11Y}
            />
          )}
        </Animated.View>
      )}
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
  // iOS pull-to-refresh indicator, overlaid in the gap the pull/refresh opens
  // above the first row (Android's spinner is the RefreshControl's own).
  pullIndicator: {
    position: 'absolute',
    top: 14,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  pullQuote: {
    // 3:2 like the source PNG; sized to sit inside the gap a full 120px pull
    // opens above the first row. tintColor recolors the brushstrokes.
    width: 132,
    height: 88,
    tintColor: palette.terminalGreen,
  },
  listContentRefreshing: {
    paddingTop: 40,
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
