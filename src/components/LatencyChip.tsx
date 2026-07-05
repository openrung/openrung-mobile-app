/**
 * On-demand latency test chip under the directory status chip. Visual clone of
 * MapStatusChip (6dp-rounded 80%-alpha panel, 12sp mono). States:
 *  - idle    -> "⏱ test latency"            (tappable)
 *  - running -> "pinging relays…"
 *  - done    -> "best: <label> <ms>ms" + age (dim once stale; tap re-tests)
 *  - failed  -> "latency test failed — tap to retry"  (#FFC0C0, tappable)
 *
 * On iOS while connected, probes ride the tunnel (not the direct path), so the
 * chip is disabled with an explanatory note instead of reporting misleading RTTs.
 */
import React from 'react';
import { Platform, Pressable, StyleSheet, StyleProp, Text, View, ViewStyle } from 'react-native';

import { useStrings } from '../i18n';
import { displayName } from '../model/countryGeo';
import { fastestCountry } from '../state/store';
import { useAppState } from '../state/store';
import { AppConfig } from '../config';
import { monoFont, palette } from '../theme';

export interface LatencyChipProps {
  isConnected: boolean;
  onRunLatency: () => void;
  style?: StyleProp<ViewStyle>;
}

export function LatencyChip({
  isConnected,
  onRunLatency,
  style,
}: LatencyChipProps): React.JSX.Element {
  const s = useStrings();
  const state = useAppState();
  const { latency } = state;

  // iOS-while-connected probes can't bypass the tunnel; disable rather than lie.
  const disabledIosTunnel = Platform.OS === 'ios' && isConnected;

  const isFailed = latency.status === 'failed';
  const isRunning = latency.status === 'running';

  const ageMs = latency.testedAtMs != null ? Date.now() - latency.testedAtMs : null;
  const isStale = ageMs != null && ageMs > AppConfig.LATENCY_RESULT_TTL_MS;

  let text: string;
  if (disabledIosTunnel) {
    text = s.latencyViaTunnelNote;
  } else if (isRunning) {
    text = s.latencyTesting;
  } else if (isFailed) {
    text = s.latencyFailed;
  } else if (latency.status === 'done') {
    const best = fastestCountry(state);
    if (best == null) {
      text = s.latencyTestAction;
    } else if (isStale) {
      text = s.latencyStale;
    } else {
      const label = displayName(best.countryCode) ?? best.countryCode;
      const age = ageMs != null && ageMs < 60_000 ? s.latencyAgeJustNow : s.latencyAgeMinutes(Math.floor((ageMs ?? 0) / 60_000));
      text = `${s.latencyBest(label, best.rttMs)} · ${age}`;
    }
  } else {
    text = s.latencyTestAction;
  }

  const tappable = !isRunning && !disabledIosTunnel;

  const label = (
    <Text style={[styles.text, isFailed && styles.textFailed, (isStale || disabledIosTunnel) && styles.textDim]}>
      {text}
    </Text>
  );

  if (tappable) {
    return (
      <Pressable onPress={onRunLatency} style={[styles.chip, style]} accessibilityRole="button">
        {label}
      </Pressable>
    );
  }
  return <View style={[styles.chip, style]}>{label}</View>;
}

const styles = StyleSheet.create({
  chip: {
    borderRadius: 6,
    backgroundColor: palette.chipBackground,
    paddingHorizontal: 10,
    paddingVertical: 6,
    alignSelf: 'flex-start',
    overflow: 'hidden',
  },
  text: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 12,
  },
  textFailed: {
    color: palette.chipFailedText,
  },
  textDim: {
    color: palette.dimText,
  },
});
