/**
 * Directory-status chip in the home header (top-right):
 *  - loading  -> "locating available exit nodes…"          (#D8FFE0)
 *  - failed   -> "couldn't load exit nodes — tap to retry"  (#FFC0C0, tappable)
 *  - loaded+0 -> "no exit nodes available right now"        (#D8FFE0, tappable)
 *  - else     -> "● %d relays online", behind the connect card's connected dot
 * 6dp-rounded, 80%-alpha panel background, 10x6dp padding, 12sp mono.
 */
import React from 'react';
import { Pressable, StyleSheet, StyleProp, Text, View, ViewStyle } from 'react-native';

import { useStrings } from '../i18n';
import type { DirectoryStatus } from '../model/exitNode';
import { monoFont, palette } from '../theme';
import { StatusDot } from './StatusDot';

export interface MapStatusChipProps {
  directoryStatus: DirectoryStatus;
  /** Relays the loaded directory lists, across every location. */
  relayCount: number;
  onRetry: () => void;
  style?: StyleProp<ViewStyle>;
}

export const MapStatusChip = React.memo(function MapStatusChipComponent({
  directoryStatus,
  relayCount,
  onRetry,
  style,
}: MapStatusChipProps): React.JSX.Element {
  const s = useStrings();

  const isFailed = directoryStatus === 'failed';
  const isEmptyLoaded = directoryStatus === 'loaded' && relayCount === 0;
  const isLoading = directoryStatus === 'loading';
  const text = isLoading
    ? s.mapLoading
    : isFailed
      ? s.mapFailed
      : isEmptyLoaded
        ? s.mapNoNodes
        : s.mapRelaysOnline(relayCount);
  const canRetry = isFailed || isEmptyLoaded;

  const label = (
    <>
      {isLoading || canRetry ? null : <StatusDot status="connected" />}
      <Text style={[styles.text, isFailed && styles.textFailed]}>{text}</Text>
    </>
  );

  if (canRetry) {
    return (
      <Pressable onPress={onRetry} style={[styles.chip, style]} accessibilityRole="button">
        {label}
      </Pressable>
    );
  }
  return <View style={[styles.chip, style]}>{label}</View>;
});

const styles = StyleSheet.create({
  chip: {
    borderRadius: 6,
    backgroundColor: palette.chipBackground,
    paddingHorizontal: 10,
    paddingVertical: 6,
    alignSelf: 'flex-start',
    overflow: 'hidden',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  text: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 12,
    // The messages without a dot are long; let them wrap inside the chip's max width.
    flexShrink: 1,
  },
  textFailed: {
    color: palette.chipFailedText,
  },
});
