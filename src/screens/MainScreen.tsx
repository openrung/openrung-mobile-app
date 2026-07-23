/**
 * Home screen. The exit-node map IS the screen by default: it fills the
 * entire viewport (running underneath the translucent tab bar) and stays
 * pannable/zoomable, while an edge vignette keeps only the center crisp and
 * dissolves the map into the app background towards every edge. The chrome
 * floats on top:
 *
 *  - header: OpenRung wordmark (with a blinking terminal cursor) + tagline on
 *    the left, the relay-directory status chip on the right;
 *  - view toggle: a MAP/LIST segmented pill under the header switches the
 *    directory presentation (persisted, store.homeViewMode). In list mode a
 *    scrollable relay list fills the middle; the map stays mounted beneath it
 *    so toggling back keeps the camera position;
 *  - ocean telemetry: a map-space HUD (inside ExitNodeMap) anchored in the
 *    Pacific directly east of Shibuya — just off the default phone view, one
 *    eastward pan away — with network totals, link status/uptime, and the
 *    last tunnel error;
 *  - bottom stack: recents pills + the glass connect card, anchored above the
 *    tab bar.
 *
 * All overlay containers use pointerEvents="box-none" so map gestures pass
 * through everywhere except the actual controls.
 */
import React, { useCallback, useEffect, useRef } from 'react';
import { Animated, Linking, Platform, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ConnectCard } from '../components/ConnectCard';
import { EdgeFade } from '../components/EdgeFade';
import { ExitNodeMap } from '../components/ExitNodeMap';
import { MapStatusChip } from '../components/MapStatusChip';
import { OceanTelemetry } from '../components/OceanTelemetry';
import { RecentsSection } from '../components/RecentsSection';
import { RelayList } from '../components/RelayList';
import { UpdateBanner } from '../components/UpdateBanner';
import { ViewModeToggle } from '../components/ViewModeToggle';
import { AppConfig } from '../config';
import { resolveLanguage, useLanguage, useStrings } from '../i18n';
import { pickLocalizedText } from '../model/updateStatus';
import { hydrateHomeViewMode, refreshDirectory, setHomeViewMode } from '../state/store';
import { dismissUpdateBanner, dismissUpdateNotice } from '../state/updateCheck';
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
  const s = useStrings();
  const { languageTag } = useLanguage();
  const { state, isConnected, isWorking, disconnect, prepareAndConnect } = useVpnState();
  const { native, directoryStatus, availableRegions, homeViewMode, connectedAtMs, update } = state;
  const isListMode = homeViewMode === 'list';
  const locale = resolveLanguage(languageTag);

  // Populate the exit-node map directory when the home screen is shown (no-op once loaded)
  // and restore the persisted map/list presentation.
  useEffect(() => {
    refreshDirectory();
    hydrateHomeViewMode();
  }, []);

  const onToggle = useCallback(() => {
    if (isConnected || isWorking) {
      disconnect().catch(() => {
        // Failures surface through the mirrored native state / debug console.
      });
    } else {
      // null target country = let the broker pick any relay.
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

  const onConnectRelay = useCallback(
    (relayId: string, countryCode: string) => {
      // Picked from an expanded multi-relay location in the list: pin that exact relay.
      prepareAndConnect(countryCode, relayId).catch(() => {
        // Reported via events.
      });
    },
    [prepareAndConnect],
  );

  const onRetryDirectory = useCallback(() => {
    refreshDirectory(true);
  }, []);

  const onOpenUpdate = useCallback(() => {
    // Pinned destination only — never a manifest-supplied URL (see AppConfig.UPDATE_URL_ANDROID).
    const url = Platform.OS === 'ios' ? AppConfig.TESTFLIGHT_URL : AppConfig.UPDATE_URL_ANDROID;
    Linking.openURL(url).catch(() => {
      // Best-effort: ignore devices without a browser handler.
    });
  }, []);

  const notice = update.notice;
  const onOpenNoticeUrl = useCallback(() => {
    if (notice?.url != null) {
      Linking.openURL(notice.url).catch(() => {
        // Best-effort.
      });
    }
  }, [notice]);

  return (
    <View style={styles.root}>
      <View
        style={StyleSheet.absoluteFill}
        // Hidden from assistive tech while the list covers it (iOS / Android).
        accessibilityElementsHidden={isListMode}
        importantForAccessibility={isListMode ? 'no-hide-descendants' : 'auto'}
      >
        <ExitNodeMap regions={availableRegions} onRegionPress={onConnectRegion}>
          <OceanTelemetry
            regions={availableRegions}
            directoryStatus={directoryStatus}
            status={native.status}
            relayLabel={native.relayLabel}
            lastError={native.lastError}
            logLines={native.logLines}
            connectedAtMs={connectedAtMs}
          />
        </ExitNodeMap>
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

        {update.tier === 'notify' && update.latestVersion != null ? (
          <UpdateBanner
            style={styles.updateBanner}
            title={s.updateBannerTitle}
            body={s.updateBannerBody(update.latestVersion)}
            primaryLabel={s.updateActionNow}
            onPrimary={onOpenUpdate}
            dismissLabel={s.updateActionLater}
            onDismiss={dismissUpdateBanner}
          />
        ) : notice != null ? (
          // Broadcast notice (verified manifests only; one card at a time — the update banner
          // outranks it, and the notice returns once the banner is dismissed or acted on).
          <UpdateBanner
            style={styles.updateBanner}
            level={notice.level}
            title={pickLocalizedText(notice.title, locale)}
            body={pickLocalizedText(notice.body, locale)}
            primaryLabel={notice.url != null ? s.noticeLearnMore : undefined}
            onPrimary={notice.url != null ? onOpenNoticeUrl : undefined}
            dismissLabel={s.noticeDismiss}
            onDismiss={() => dismissUpdateNotice(notice.id)}
          />
        ) : null}

        <ViewModeToggle mode={homeViewMode} onChange={setHomeViewMode} style={styles.viewToggle} />

        {isListMode ? (
          <RelayList
            regions={availableRegions}
            directoryStatus={directoryStatus}
            onRelayPress={onConnectRelay}
            onRetry={onRetryDirectory}
            refreshing={directoryStatus === 'loading'}
            style={styles.list}
          />
        ) : (
          <View style={styles.spacer} pointerEvents="none" />
        )}

        <View style={styles.bottomStack} pointerEvents="box-none">
          <RecentsSection recents={native.recents} onPress={onConnectRegion} />
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
  updateBanner: {
    marginTop: 14,
  },
  viewToggle: {
    marginTop: 14,
  },
  spacer: {
    flex: 1,
  },
  list: {
    flex: 1,
    marginVertical: 14,
  },
  bottomStack: {
    gap: 14,
  },
});
