/**
 * Full-screen vignette laid over the map: the center stays perfectly clear
 * and the map dissolves into the near-black app background towards the edges
 * (radial fade), with extra top/bottom bands so the header and the floating
 * connect card always sit on legible dark glass. Renders with
 * pointerEvents="none", so pan/zoom gestures pass straight through to the
 * map underneath.
 */
import React from 'react';
import { StyleSheet } from 'react-native';
import Svg, { Defs, LinearGradient, RadialGradient, Rect, Stop } from 'react-native-svg';

import { palette } from '../theme';

const FADE = palette.screen;

export function EdgeFade(): React.JSX.Element {
  return (
    <Svg style={StyleSheet.absoluteFill} pointerEvents="none">
      <Defs>
        {/* Clear center -> soft mist -> near-opaque background at the corners. */}
        <RadialGradient id="edge-vignette" cx="50%" cy="46%" rx="58%" ry="52%">
          <Stop offset="0" stopColor={FADE} stopOpacity="0" />
          <Stop offset="0.52" stopColor={FADE} stopOpacity="0" />
          <Stop offset="0.72" stopColor={FADE} stopOpacity="0.38" />
          <Stop offset="0.88" stopColor={FADE} stopOpacity="0.74" />
          <Stop offset="1" stopColor={FADE} stopOpacity="0.94" />
        </RadialGradient>
        <LinearGradient id="edge-top" x1="0" y1="0" x2="0" y2="1">
          <Stop offset="0" stopColor={FADE} stopOpacity="0.88" />
          <Stop offset="1" stopColor={FADE} stopOpacity="0" />
        </LinearGradient>
        <LinearGradient id="edge-bottom" x1="0" y1="0" x2="0" y2="1">
          <Stop offset="0" stopColor={FADE} stopOpacity="0" />
          <Stop offset="1" stopColor={FADE} stopOpacity="0.92" />
        </LinearGradient>
      </Defs>
      <Rect x="0" y="0" width="100%" height="100%" fill="url(#edge-vignette)" />
      <Rect x="0" y="0" width="100%" height="18%" fill="url(#edge-top)" />
      <Rect x="0" y="72%" width="100%" height="28%" fill="url(#edge-bottom)" />
    </Svg>
  );
}
