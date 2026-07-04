/**
 * Floating glass control card anchored above the tab bar on the home screen:
 * a live status row (pulsing dot + uppercase status + relay location), the
 * primary connect action, and the fail-closed footer line.
 *
 * The connect button narrates the whole connection lifecycle instead of
 * flipping between two labels:
 *
 *  - disconnected/failed: outlined, "CONNECT";
 *  - preparing/connecting: a green disc grows out of the exact point the user
 *    tapped (clipped by the button), creeping towards ~85% while the tunnel
 *    is negotiated, with the live status as the label;
 *  - connected: the fill snaps to 100% — a solid green button, "DISCONNECT";
 *  - disconnecting: the fill drains back toward the last tap point.
 *
 * Label/icon are rendered twice (green for the unfilled base, dark for the
 * green fill) and crossfaded as the disc passes underneath them, so the text
 * stays legible at every fill level. All animations ride the native driver
 * (transform scale + opacity only).
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  Pressable,
  StyleSheet,
  Text,
  View,
  type GestureResponderEvent,
  type LayoutChangeEvent,
} from 'react-native';

import { statusLabel, useStrings, type Strings } from '../i18n';
import type { ConnectionStatus } from '../native/types';
import { monoFont, palette, tokens } from '../theme';
import { PowerIcon } from './Icons';

export interface ConnectCardProps {
  status: ConnectionStatus;
  relayLabel: string | null;
  isConnected: boolean;
  isWorking: boolean;
  onToggle: () => void;
}

function dotColor(status: ConnectionStatus): string {
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

/** Button caption per lifecycle stage (working states show the live status). */
function buttonLabel(s: Strings, status: ConnectionStatus): string {
  switch (status) {
    case 'connected':
      return s.actionDisconnect;
    case 'preparing':
    case 'connecting':
    case 'disconnecting':
      return statusLabel(s, status).toUpperCase();
    case 'disconnected':
    case 'failed':
      return s.actionConnect;
  }
}

/** 10px status dot with a soft breathing halo while connected or working. */
function StatusDot({ status }: { status: ConnectionStatus }): React.JSX.Element {
  const pulse = useRef(new Animated.Value(0)).current;
  const animate = status !== 'disconnected' && status !== 'failed';

  useEffect(() => {
    if (!animate) {
      pulse.setValue(0);
      return;
    }
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, {
          toValue: 1,
          duration: 1100,
          easing: Easing.out(Easing.quad),
          useNativeDriver: true,
        }),
        Animated.timing(pulse, {
          toValue: 0,
          duration: 1100,
          easing: Easing.in(Easing.quad),
          useNativeDriver: true,
        }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [animate, pulse]);

  const color = dotColor(status);
  return (
    <View style={styles.dotWrap}>
      <Animated.View
        style={[
          styles.dotHalo,
          {
            backgroundColor: color,
            opacity: pulse.interpolate({ inputRange: [0, 1], outputRange: [0, 0.35] }),
            transform: [{ scale: pulse.interpolate({ inputRange: [0, 1], outputRange: [0.6, 1] }) }],
          },
        ]}
      />
      <View style={[styles.dot, { backgroundColor: color }]} />
    </View>
  );
}

/** Origin + radius of the fill disc; radius always reaches the farthest corner. */
interface FillGeometry {
  x: number;
  y: number;
  r: number;
}

export function ConnectCard({
  status,
  relayLabel,
  isConnected,
  isWorking,
  onToggle,
}: ConnectCardProps): React.JSX.Element {
  const s = useStrings();

  const sizeRef = useRef({ w: 0, h: 0 });
  const [fillGeometry, setFillGeometry] = useState<FillGeometry | null>(null);
  const fill = useRef(new Animated.Value(0)).current;

  const geometryFor = useCallback((x: number, y: number): FillGeometry => {
    const { w, h } = sizeRef.current;
    const r = Math.max(
      Math.hypot(x, y),
      Math.hypot(w - x, y),
      Math.hypot(x, h - y),
      Math.hypot(w - x, h - y),
    );
    return { x, y, r: Math.max(r, 1) };
  }, []);

  const onLayout = useCallback((event: LayoutChangeEvent) => {
    const { width, height } = event.nativeEvent.layout;
    sizeRef.current = { w: width, h: height };
  }, []);

  const onPressIn = useCallback(
    (event: GestureResponderEvent) => {
      // Anchor the fill at the touch point — but never move a disc that is
      // mid-growth (cancel taps while connecting would make it jump).
      if (!isWorking) {
        setFillGeometry(geometryFor(event.nativeEvent.locationX, event.nativeEvent.locationY));
      }
    },
    [isWorking, geometryFor],
  );

  // Drive the fill from the connection lifecycle.
  useEffect(() => {
    if (status === 'preparing' || status === 'connecting') {
      // Connect may also start from a map marker or a recents pill — without
      // a button tap the disc grows from the center.
      setFillGeometry(current => {
        if (current != null) {
          return current;
        }
        const { w, h } = sizeRef.current;
        return geometryFor(w / 2, h / 2);
      });
      // Creep towards "almost there" while the tunnel is negotiated…
      Animated.timing(fill, {
        toValue: 0.85,
        duration: 9000,
        easing: Easing.out(Easing.cubic),
        useNativeDriver: true,
      }).start();
    } else if (status === 'connected') {
      // …and complete the fill the moment the native side reports connected.
      Animated.timing(fill, {
        toValue: 1,
        duration: 420,
        easing: Easing.out(Easing.quad),
        useNativeDriver: true,
      }).start();
    } else if (status === 'disconnecting') {
      Animated.timing(fill, {
        toValue: 0,
        duration: 600,
        easing: Easing.in(Easing.quad),
        useNativeDriver: true,
      }).start();
    } else {
      // disconnected / failed
      Animated.timing(fill, {
        toValue: 0,
        duration: 250,
        easing: Easing.in(Easing.quad),
        useNativeDriver: true,
      }).start();
    }
  }, [status, fill, geometryFor]);

  const label = buttonLabel(s, status);
  // The dark copy fades in as the disc sweeps under the centered content.
  const darkContentOpacity = fill.interpolate({
    inputRange: [0, 0.45, 0.75, 1],
    outputRange: [0, 0.1, 1, 1],
  });

  return (
    <View style={styles.card}>
      <View style={styles.statusRow}>
        <StatusDot status={status} />
        <Text style={styles.statusText} numberOfLines={1}>
          {statusLabel(s, status).toUpperCase()}
        </Text>
        <Text style={styles.relayText} numberOfLines={1}>
          {relayLabel ?? s.relayAuto}
        </Text>
      </View>

      <Pressable
        onLayout={onLayout}
        onPressIn={onPressIn}
        onPress={onToggle}
        style={({ pressed }) => [
          styles.button,
          isConnected && styles.buttonConnectedGlow,
          pressed && styles.buttonPressed,
        ]}
        accessibilityRole="button"
        accessibilityLabel={label}
      >
        {fillGeometry != null ? (
          <Animated.View
            pointerEvents="none"
            style={[
              styles.fillDisc,
              {
                left: fillGeometry.x - fillGeometry.r,
                top: fillGeometry.y - fillGeometry.r,
                width: fillGeometry.r * 2,
                height: fillGeometry.r * 2,
                borderRadius: fillGeometry.r,
                transform: [{ scale: fill }],
              },
            ]}
          />
        ) : null}
        <View style={styles.buttonContent} pointerEvents="none">
          <PowerIcon color={palette.terminalGreen} size={18} strokeWidth={2.2} />
          <Text style={styles.buttonLabelGreen}>{label}</Text>
        </View>
        <Animated.View
          style={[styles.buttonContentOverlay, { opacity: darkContentOpacity }]}
          pointerEvents="none"
        >
          <PowerIcon color={palette.onGreenText} size={18} strokeWidth={2.2} />
          <Text style={styles.buttonLabelDark}>{label}</Text>
        </Animated.View>
      </Pressable>

      <Text style={styles.footer} numberOfLines={2}>
        {isConnected ? s.trafficRouteConnected : s.trafficRouteDisconnected}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: tokens.radiusLg,
    backgroundColor: tokens.glass,
    borderWidth: 1,
    borderColor: tokens.glassBorder,
    padding: 18,
    gap: 14,
  },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  dotWrap: {
    width: 18,
    height: 18,
    alignItems: 'center',
    justifyContent: 'center',
  },
  dotHalo: {
    position: 'absolute',
    width: 18,
    height: 18,
    borderRadius: 9,
  },
  dot: {
    width: 9,
    height: 9,
    borderRadius: 4.5,
  },
  statusText: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 12,
    letterSpacing: 1.5,
  },
  relayText: {
    flex: 1,
    textAlign: 'right',
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 12,
  },
  // Outlined base at every stage; the green disc growing inside it is what
  // turns it into the "solid" connected button.
  button: {
    height: 56,
    borderRadius: tokens.radiusMd,
    borderWidth: 1.5,
    borderColor: palette.terminalGreen,
    backgroundColor: 'rgba(101, 245, 138, 0.08)',
    overflow: 'hidden',
    justifyContent: 'center',
  },
  buttonConnectedGlow: {
    shadowColor: tokens.glow,
    shadowOpacity: 1,
    shadowRadius: 14,
    shadowOffset: { width: 0, height: 0 },
    elevation: 6,
  },
  buttonPressed: {
    opacity: 0.85,
  },
  fillDisc: {
    position: 'absolute',
    backgroundColor: palette.terminalGreen,
  },
  buttonContent: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
  },
  buttonContentOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
  },
  buttonLabelGreen: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 14,
    fontWeight: '900',
    letterSpacing: 2,
  },
  buttonLabelDark: {
    color: palette.onGreenText,
    fontFamily: monoFont,
    fontSize: 14,
    fontWeight: '900',
    letterSpacing: 2,
  },
  footer: {
    alignSelf: 'center',
    textAlign: 'center',
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 10,
    letterSpacing: 0.4,
  },
});
