/**
 * Window-adaptive layout helpers. Layout decisions key off safe-area insets and
 * the available width, never device idiom or orientation: the same code runs
 * on a phone, an iPad window and both iPhone Duo displays, where the status
 * bar and the native tab bar can sit on a side edge rather than top/bottom.
 */
import { useMemo } from 'react';
import { Platform, StyleSheet } from 'react-native';
import {
  useSafeAreaInsets,
  useSafeAreaFrame,
  type EdgeInsets,
} from 'react-native-safe-area-context';

import { tokens } from './theme';

const TWO_COLUMN_MIN_WIDTH = 760;
const COLUMN_GAP = 24;

/**
 * Safe-area insets for a tab scene, tab bar included. iOS: the scene's own
 * SafeAreaProvider (NativeTabs) already reports the native bar on whichever
 * edge it occupies. Android: the JS TabBar is a fixed-height bottom overlay.
 */
export function useTabSceneInsets(): EdgeInsets {
  const insets = useSafeAreaInsets();
  return useMemo(
    () =>
      Platform.OS === 'ios'
        ? insets
        : { ...insets, bottom: insets.bottom + tokens.tabBarHeight },
    [insets],
  );
}

/** Fit one or two readable columns inside the current scene, including after resizing. */
export function useTabSceneColumns() {
  const insets = useTabSceneInsets();
  const { width } = useSafeAreaFrame();
  const availableWidth = width - insets.left - insets.right - tokens.edge * 2;
  const twoColumns = availableWidth >= TWO_COLUMN_MIN_WIDTH;
  const contentWidth = Math.max(
    0,
    Math.min(
      availableWidth,
      twoColumns ? tokens.contentMaxWidth * 2 + COLUMN_GAP : tokens.contentMaxWidth,
    ),
  );
  const columnWidth = twoColumns ? (contentWidth - COLUMN_GAP) / 2 : contentWidth;
  return { insets, twoColumns, contentWidth, columnWidth };
}

/** Screen padding: safe area (including side rails) plus the standard edge gutter. */
export function edgePadding(insets: EdgeInsets, vertical: number) {
  return {
    paddingTop: insets.top + vertical,
    paddingBottom: insets.bottom + vertical,
    paddingLeft: insets.left + tokens.edge,
    paddingRight: insets.right + tokens.edge,
  };
}

export const layout = StyleSheet.create({
  twoColumns: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: COLUMN_GAP,
  },
  /** Centered content column, capped on regular-width windows. */
  column: {
    width: '100%',
    maxWidth: tokens.contentMaxWidth,
    alignSelf: 'center',
  },
});
