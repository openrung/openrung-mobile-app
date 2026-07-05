/**
 * One compact mono line of live tunnel traffic inside the ConnectCard while
 * connected: instantaneous rates plus session totals, e.g.
 * "↓ 3.2 Mbps ↑ 410 Kbps · Σ ↓128 MB ↑12 MB". Digits use tabular numerals so
 * the line doesn't jitter at the 2s sample cadence.
 */
import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { useStrings } from '../i18n';
import type { TrafficStats } from '../native/types';
import { monoFont, palette } from '../theme';
import { formatBitrate, formatBytes } from '../util/format';

export interface TrafficStatsRowProps {
  traffic: TrafficStats;
}

export function TrafficStatsRow({ traffic }: TrafficStatsRowProps): React.JSX.Element {
  const s = useStrings();
  const down = formatBitrate(traffic.downBps);
  const up = formatBitrate(traffic.upBps);

  return (
    <View
      style={styles.row}
      accessibilityLabel={s.trafficStatsAccessibility(down, up)}
      accessible
    >
      <Text style={styles.rates} numberOfLines={1}>
        {`↓ ${down}  ↑ ${up}`}
      </Text>
      <Text style={styles.totals} numberOfLines={1}>
        {`Σ ↓${formatBytes(traffic.downTotalBytes)} ↑${formatBytes(traffic.upTotalBytes)}`}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
  },
  rates: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 11,
    fontVariant: ['tabular-nums'],
  },
  totals: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 10,
    fontVariant: ['tabular-nums'],
  },
});
