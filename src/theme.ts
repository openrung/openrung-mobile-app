import { Platform } from 'react-native';

import type { ConnectionStatus } from './native/types';

/**
 * Terminal-green-on-black palette, hex-for-hex from the production Compose UI
 * (contract §5). ALL text in the app renders in `monoFont`.
 */
export const palette = {
  /** Screen background. */
  screen: '#030604',
  /** Panel/card background. */
  panel: '#07110B',
  /** All 1dp panel borders (dim green). */
  borderDim: '#294F35',
  /** Titles, accents, buttons, markers, icons. */
  terminalGreen: '#65F58A',
  /** Body text. */
  bodyText: '#D8FFE0',
  /** Subtitle / dim / footer text. */
  dimText: '#7DA989',
  /** Relay line text. */
  relayLine: '#A5F2B5',
  /** Connect button container when connected or working. */
  connectedButton: '#B6F579',
  /** Text on green buttons. */
  onGreenText: '#061008',
  /** Console error text. */
  consoleError: '#FFA0A0',
  /** Map chip text in the FAILED state. */
  chipFailedText: '#FFC0C0',
  /** Map chip background: panel black at 80% alpha (Compose 0xCC07110B -> RN #RRGGBBAA). */
  chipBackground: '#07110BCC',
  /** FAB container. */
  fabBackground: '#0D1C12',
  /** FAB content (icon). */
  fabContent: '#65F58A',
  /** Map marker stroke / count-label text halo. */
  markerStroke: '#04140A',
} as const;

// Individual named exports for convenience (same values as `palette`).
export const screen = palette.screen;
export const panel = palette.panel;
export const borderDim = palette.borderDim;
export const terminalGreen = palette.terminalGreen;
export const bodyText = palette.bodyText;
export const dimText = palette.dimText;
export const relayLine = palette.relayLine;
export const connectedButton = palette.connectedButton;
export const onGreenText = palette.onGreenText;
export const consoleError = palette.consoleError;
export const chipFailedText = palette.chipFailedText;
export const chipBackground = palette.chipBackground;
export const fabBackground = palette.fabBackground;
export const fabContent = palette.fabContent;
export const markerStroke = palette.markerStroke;

/** Every text element is monospace, exactly like the production app. */
export const monoFont = Platform.select({ ios: 'Menlo', default: 'monospace' });

/**
 * Product design tokens layered on top of the terminal palette. The hex
 * palette above stays byte-for-byte identical to production; everything the
 * redesigned shell adds (glass surfaces, glows, radii, tab bar) lives here so
 * a future reskin only touches this block.
 */
export const tokens = {
  /** Translucent panel used for cards floating over the map. */
  glass: 'rgba(7, 17, 11, 0.86)',
  /** Denser glass for the tab bar (map stays faintly visible beneath). */
  glassDense: 'rgba(3, 6, 4, 0.92)',
  /** Hairline borders on glass surfaces. */
  glassBorder: 'rgba(41, 79, 53, 0.9)',
  /** Neon glow color (iOS shadowColor; borders/rings elsewhere). */
  glow: 'rgba(101, 245, 138, 0.55)',
  /** Softer glow for idle/ambient elements. */
  glowSoft: 'rgba(101, 245, 138, 0.25)',
  /** Status-dot color while connecting/preparing/disconnecting. */
  working: '#EAF565',
  /** Corner radii. */
  radiusSm: 10,
  radiusMd: 16,
  radiusLg: 22,
  /** Fixed tab-bar content height (safe-area inset is added below it). */
  tabBarHeight: 62,
  /** Screen edge padding. */
  edge: 20,
} as const;

/**
 * Status-dot colour for live-status readouts (connect card, ocean telemetry):
 * green when connected, amber while working, red on failure, dim when idle.
 */
export function statusDotColor(status: ConnectionStatus): string {
  switch (status) {
    case 'connected':
      return palette.terminalGreen;
    case 'preparing':
    case 'connecting':
    case 'disconnecting':
      return tokens.working;
    case 'failed':
      return palette.consoleError;
    case 'disconnected':
      return palette.dimText;
  }
}
