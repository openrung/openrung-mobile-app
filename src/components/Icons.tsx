/**
 * Hand-drawn stroke icons (react-native-svg) for the tab bar and the connect
 * card. All icons share the same 24x24 viewBox, 1.8px rounded strokes and a
 * `color`/`size` API so they inherit whatever tint the caller passes —
 * matching the terminal-green-on-black aesthetic without an icon-font
 * dependency.
 */
import React from 'react';
import Svg, { Circle, Line, Path } from 'react-native-svg';

export interface IconProps {
  color: string;
  size?: number;
  strokeWidth?: number;
}

/** House outline (Home tab). */
export function HomeIcon({ color, size = 22, strokeWidth = 1.8 }: IconProps): React.JSX.Element {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19v-8.5Z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path
        d="M9.5 20.5v-6h5v6"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Svg>
  );
}

/** Three tuning sliders (Settings tab). */
export function SlidersIcon({ color, size = 22, strokeWidth = 1.8 }: IconProps): React.JSX.Element {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Line x1="4" y1="7" x2="20" y2="7" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Line x1="4" y1="12" x2="20" y2="12" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Line x1="4" y1="17" x2="20" y2="17" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Circle cx="9" cy="7" r="2.1" fill="none" stroke={color} strokeWidth={strokeWidth} />
      <Circle cx="15" cy="12" r="2.1" fill="none" stroke={color} strokeWidth={strokeWidth} />
      <Circle cx="7" cy="17" r="2.1" fill="none" stroke={color} strokeWidth={strokeWidth} />
    </Svg>
  );
}

/** Info circle (About tab). */
export function InfoIcon({ color, size = 22, strokeWidth = 1.8 }: IconProps): React.JSX.Element {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Circle cx="12" cy="12" r="8.5" stroke={color} strokeWidth={strokeWidth} />
      <Line x1="12" y1="11" x2="12" y2="16" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Circle cx="12" cy="7.8" r="1.15" fill={color} />
    </Svg>
  );
}

/** Folded tri-panel map outline (home view toggle). */
export function MapIcon({ color, size = 22, strokeWidth = 1.8 }: IconProps): React.JSX.Element {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M9 4.5 3.5 6.5v13L9 17.5l6 2 5.5-2v-13L15 6.5l-6-2Z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Line x1="9" y1="4.5" x2="9" y2="17.5" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Line x1="15" y1="6.5" x2="15" y2="19.5" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

/** Bulleted rows (home view toggle). */
export function ListIcon({ color, size = 22, strokeWidth = 1.8 }: IconProps): React.JSX.Element {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Circle cx="5" cy="6.5" r="1.15" fill={color} />
      <Circle cx="5" cy="12" r="1.15" fill={color} />
      <Circle cx="5" cy="17.5" r="1.15" fill={color} />
      <Line x1="9.5" y1="6.5" x2="20" y2="6.5" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Line x1="9.5" y1="12" x2="20" y2="12" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Line x1="9.5" y1="17.5" x2="20" y2="17.5" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

/** Power symbol (connect button). */
export function PowerIcon({ color, size = 22, strokeWidth = 1.8 }: IconProps): React.JSX.Element {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M7.2 6.4a8 8 0 1 0 9.6 0"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
      />
      <Line x1="12" y1="3" x2="12" y2="11" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}
