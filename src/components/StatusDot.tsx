/**
 * Live-status dot shared by the connect card and the header's relay-count chip.
 */
import React, { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';

import type { ConnectionStatus } from '../native/types';
import { statusDotColor } from '../theme';

/** 10px status dot with a soft breathing halo while connected or working. */
export function StatusDot({ status }: { status: ConnectionStatus }): React.JSX.Element {
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

  const color = statusDotColor(status);
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

const styles = StyleSheet.create({
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
});
