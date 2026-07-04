/**
 * Floating glass control card anchored above the tab bar on the home screen:
 * a live status row (pulsing dot + uppercase status + relay location), the
 * primary CONNECT action (solid neon while disconnected, quiet outline while
 * connected/working, so the loud CTA is always "get me connected"), and the
 * fail-closed footer line.
 */
import React, { useEffect, useRef } from 'react';
import { Animated, Easing, Pressable, StyleSheet, Text, View } from 'react-native';

import { statusLabel, useStrings } from '../i18n';
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

export function ConnectCard({
  status,
  relayLabel,
  isConnected,
  isWorking,
  onToggle,
}: ConnectCardProps): React.JSX.Element {
  const s = useStrings();
  const buttonConnected = isConnected || isWorking;

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
        onPress={onToggle}
        style={({ pressed }) => [
          styles.button,
          buttonConnected ? styles.buttonOutline : styles.buttonSolid,
          pressed && styles.buttonPressed,
        ]}
        accessibilityRole="button"
      >
        <PowerIcon
          color={buttonConnected ? palette.terminalGreen : palette.onGreenText}
          size={18}
          strokeWidth={2.2}
        />
        <Text style={[styles.buttonLabel, buttonConnected && styles.buttonLabelOutline]}>
          {buttonConnected ? s.actionDisconnect : s.actionConnect}
        </Text>
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
  button: {
    height: 56,
    borderRadius: tokens.radiusMd,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
  },
  buttonSolid: {
    backgroundColor: palette.terminalGreen,
    shadowColor: tokens.glow,
    shadowOpacity: 1,
    shadowRadius: 14,
    shadowOffset: { width: 0, height: 0 },
    elevation: 6,
  },
  buttonOutline: {
    backgroundColor: 'rgba(101, 245, 138, 0.08)',
    borderWidth: 1.5,
    borderColor: palette.terminalGreen,
  },
  buttonPressed: {
    opacity: 0.85,
  },
  buttonLabel: {
    color: palette.onGreenText,
    fontFamily: monoFont,
    fontSize: 14,
    fontWeight: '900',
    letterSpacing: 2,
  },
  buttonLabelOutline: {
    color: palette.terminalGreen,
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
