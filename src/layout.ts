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
  type EdgeInsets,
} from 'react-native-safe-area-context';

import { tokens } from './theme';

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
  /** Centered content column, capped on regular-width windows. */
  column: {
    width: '100%',
    maxWidth: tokens.contentMaxWidth,
    alignSelf: 'center',
  },
});
