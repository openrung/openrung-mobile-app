/**
 * Directory-status chip overlaid on the exit-node map (top-left). Mirrors the
 * production MapStatusChip exactly:
 *  - loading  -> "locating available exit nodes…"          (#D8FFE0)
 *  - failed   -> "couldn't load exit nodes — tap to retry"  (#FFC0C0, tappable)
 *  - loaded+0 -> "no exit nodes available right now"        (#D8FFE0, tappable)
 *  - else     -> "%d locations available"                   (#D8FFE0)
 * 6dp-rounded, 80%-alpha panel background, 10x6dp padding, 12sp mono.
 */
import React from 'react';
import { Pressable, StyleSheet, StyleProp, Text, View, ViewStyle } from 'react-native';

import { useStrings } from '../i18n';
import type { DirectoryStatus } from '../model/exitNode';
import { monoFont, palette } from '../theme';

export interface MapStatusChipProps {
  directoryStatus: DirectoryStatus;
  regionCount: number;
  onRetry: () => void;
  style?: StyleProp<ViewStyle>;
}

export function MapStatusChip({
  directoryStatus,
  regionCount,
  onRetry,
  style,
}: MapStatusChipProps): React.JSX.Element {
  const s = useStrings();

  const isFailed = directoryStatus === 'failed';
  const isEmptyLoaded = directoryStatus === 'loaded' && regionCount === 0;
  const text =
    directoryStatus === 'loading'
      ? s.mapLoading
      : isFailed
        ? s.mapFailed
        : isEmptyLoaded
          ? s.mapNoNodes
          : s.mapNodesAvailable(regionCount);
  const canRetry = isFailed || isEmptyLoaded;

  const label = (
    <Text style={[styles.text, isFailed && styles.textFailed]}>{text}</Text>
  );

  if (canRetry) {
    return (
      <Pressable onPress={onRetry} style={[styles.chip, style]} accessibilityRole="button">
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
});
