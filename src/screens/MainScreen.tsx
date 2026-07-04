/**
 * Home screen. The exit-node map IS the screen: it fills the entire viewport
 * (running underneath the translucent tab bar) and stays pannable/zoomable,
 * while an edge vignette keeps only the center crisp and dissolves the map
 * into the app background towards every edge. The chrome floats on top:
 *
 *  - header: OpenRung wordmark (with a blinking terminal cursor) + tagline on
 *    the left, the relay-directory status chip on the right;
 *  - bottom stack: recents pills + the glass connect card, anchored above the
 *    tab bar.
 *
 * All overlay containers use pointerEvents="box-none" so map gestures pass
 * through everywhere except the actual controls.
 */
import React, { useCallback, useEffect, useRef } from 'react';
import { Animated, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ConnectCard } from '../components/ConnectCard';
import { EdgeFade } from '../components/EdgeFade';
import { ExitNodeMap } from '../components/ExitNodeMap';
import { MapStatusChip } from '../components/MapStatusChip';
import { RecentsSection } from '../components/RecentsSection';
import { useStrings } from '../i18n';
import { refreshDirectory } from '../state/store';
import { useVpnState } from '../state/useVpnState';
import { monoFont, palette, tokens } from '../theme';

/** Terminal-prompt wordmark: "OpenRung" + blinking block cursor + tagline. */
function Wordmark(): React.JSX.Element {
  const s = useStrings();
  const blink = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.delay(560),
        Animated.timing(blink, { toValue: 0, duration: 60, useNativeDriver: true }),
        Animated.delay(560),
        Animated.timing(blink, { toValue: 1, duration: 60, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [blink]);

  return (
    <View>
      <View style={styles.wordmarkRow}>
        <Text style={styles.wordmark}>{s.appName}</Text>
        <Animated.Text style={[styles.cursor, { opacity: blink }]}>▍</Animated.Text>
      </View>
      <Text style={styles.tagline}>{s.homeTagline}</Text>
    </View>
  );
}

export function MainScreen(): React.JSX.Element {
  const insets = useSafeAreaInsets();
  const { state, isConnected, isWorking, disconnect, prepareAndConnect } = useVpnState();
  const { native, directoryStatus, availableRegions } = state;

  // Populate the exit-node map directory when the home screen is shown (no-op once loaded).
  useEffect(() => {
    refreshDirectory();
  }, []);

  const onToggle = useCallback(() => {
    if (isConnected || isWorking) {
      disconnect().catch(() => {
        // Failures surface through the mirrored native state / debug console.
      });
    } else {
      // null target country = let the broker pick any volunteer.
      prepareAndConnect(null).catch(() => {
        // Same: connect failures are reported via openrungStateChanged events.
      });
    }
  }, [isConnected, isWorking, disconnect, prepareAndConnect]);

  const onConnectRegion = useCallback(
    (countryCode: string) => {
      // Same flow as the button; works even while already connected (switch).
      prepareAndConnect(countryCode).catch(() => {
        // Reported via events.
      });
    },
    [prepareAndConnect],
  );

  const onRetryDirectory = useCallback(() => {
    refreshDirectory(true);
  }, []);

  return (
    <View style={styles.root}>
      <View style={StyleSheet.absoluteFill}>
        <ExitNodeMap regions={availableRegions} onRegionPress={onConnectRegion} />
      </View>
      <EdgeFade />

      <View
        style={[
          styles.overlay,
          {
            paddingTop: insets.top + 14,
            // Clear the translucent tab bar (its own safe-area padding included).
            paddingBottom: tokens.tabBarHeight + insets.bottom + 14,
          },
        ]}
        pointerEvents="box-none"
      >
        <View style={styles.header} pointerEvents="box-none">
          <Wordmark />
          <MapStatusChip
            directoryStatus={directoryStatus}
            regionCount={availableRegions.length}
            onRetry={onRetryDirectory}
            style={styles.headerChip}
          />
        </View>

        <View style={styles.spacer} pointerEvents="none" />

        <View style={styles.bottomStack} pointerEvents="box-none">
          <RecentsSection recents={native.recents} />
          <ConnectCard
            status={native.status}
            relayLabel={native.relayLabel}
            isConnected={isConnected}
            isWorking={isWorking}
            onToggle={onToggle}
          />
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
  },
  overlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    paddingHorizontal: tokens.edge,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: 12,
  },
  headerChip: {
    marginTop: 4,
    maxWidth: 180,
  },
  wordmarkRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  wordmark: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 26,
    letterSpacing: 0.5,
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 12,
  },
  cursor: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 24,
    marginLeft: 2,
  },
  tagline: {
    marginTop: 2,
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    letterSpacing: 1.2,
  },
  spacer: {
    flex: 1,
  },
  bottomStack: {
    gap: 14,
  },
});
