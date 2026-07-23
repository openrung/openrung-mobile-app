/**
 * OpenRung mobile app root. Three bottom tabs (Home / Settings / About us)
 * over a plain state machine — no nav library, screens swap instantly.
 *
 * iOS renders the tabs through the system TabView (NativeTabs), so the bar is
 * the real native one — Liquid Glass on iOS 26+ — and the native tab
 * controller keeps the home map mounted across switches. Android keeps the
 * custom JS TabBar: the home screen (full-screen map) stays mounted
 * underneath the other tabs so the MapLibre view keeps its camera/tiles, and
 * Settings/About render as opaque overlays above it.
 *
 * On both platforms, deep screens (debug console, split tunneling, licenses,
 * license full text) push over everything including the tab bar, with
 * hardware back mapped exactly like their in-header back arrows:
 * LICENSE_TEXT -> LICENSES -> ABOUT, DEBUG -> SETTINGS,
 * SPLIT_TUNNELING -> SETTINGS, any tab -> HOME, HOME -> system default
 * (exit).
 */
import React, { useCallback, useEffect, useState } from 'react';
import { BackHandler, Platform, StatusBar, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { NativeTabs } from './src/components/NativeTabs';
import { TabBar, type AppTab } from './src/components/TabBar';
import { LanguageProvider } from './src/i18n';
import { AboutScreen } from './src/screens/AboutScreen';
import { DebugScreen } from './src/screens/DebugScreen';
import { LicenseTextScreen } from './src/screens/LicenseTextScreen';
import { LicensesScreen } from './src/screens/LicensesScreen';
import { MainScreen } from './src/screens/MainScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import { SplitTunnelingScreen } from './src/screens/SplitTunnelingScreen';
import { UpdateRequiredScreen } from './src/screens/UpdateRequiredScreen';
import { hydrateSplitTunnel, useAppState } from './src/state/store';
import { startUpdateCheck } from './src/state/updateCheck';
import { palette } from './src/theme';

/** Screens pushed over the tabs (each has its own back arrow). */
type SubRoute = 'DEBUG' | 'SPLIT_TUNNELING' | 'LICENSES' | 'LICENSE_TEXT' | null;

function App(): React.JSX.Element {
  // Kick off the fail-open update check (hydrate + throttled fetch + foreground re-checks).
  // It never gates rendering: the manifest only ever changes what AppRoutes shows.
  useEffect(() => startUpdateCheck(), []);

  // Hydrate the split-tunnel slice at launch (not only when the sub-screen mounts) so the
  // Settings row reflects the routing the native side actually applies — otherwise it would read
  // "Off / all traffic through the relay" while native bypass rules are live, misreporting the
  // leak surface in a censorship-circumvention app.
  useEffect(() => {
    // hydrateSplitTunnel is best-effort and never rejects.
    hydrateSplitTunnel();
  }, []);

  return (
    <SafeAreaProvider>
      <LanguageProvider>
        <StatusBar barStyle="light-content" translucent backgroundColor="transparent" />
        <AppRoutes />
      </LanguageProvider>
    </SafeAreaProvider>
  );
}

function AppRoutes(): React.JSX.Element {
  const [tab, setTab] = useState<AppTab>('home');
  const [subRoute, setSubRoute] = useState<SubRoute>(null);
  const { update } = useAppState();

  const goBack = useCallback((): boolean => {
    if (subRoute === 'LICENSE_TEXT') {
      setSubRoute('LICENSES');
      return true;
    }
    if (subRoute != null) {
      setSubRoute(null);
      return true;
    }
    if (tab !== 'home') {
      setTab('home');
      return true;
    }
    return false; // system default on home: exit
  }, [subRoute, tab]);

  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', goBack);
    return () => subscription.remove();
  }, [goBack]);

  const onSelectTab = useCallback((next: AppTab) => {
    setSubRoute(null);
    setTab(next);
  }, []);

  let subScreen: React.JSX.Element | null = null;
  switch (subRoute) {
    case 'DEBUG':
      subScreen = <DebugScreen onBack={() => setSubRoute(null)} />;
      break;
    case 'SPLIT_TUNNELING':
      subScreen = <SplitTunnelingScreen onBack={() => setSubRoute(null)} />;
      break;
    case 'LICENSES':
      subScreen = (
        <LicensesScreen
          onBack={() => setSubRoute(null)}
          onOpenFullText={() => setSubRoute('LICENSE_TEXT')}
        />
      );
      break;
    case 'LICENSE_TEXT':
      subScreen = <LicenseTextScreen onBack={() => setSubRoute('LICENSES')} />;
      break;
    default:
      break;
  }

  const renderScene = useCallback(
    (scene: AppTab): React.JSX.Element => (
      <View style={styles.scene}>
        {scene === 'home' ? (
          <MainScreen />
        ) : scene === 'settings' ? (
          <SettingsScreen
            onOpenDebug={() => setSubRoute('DEBUG')}
            onOpenSplitTunneling={() => setSubRoute('SPLIT_TUNNELING')}
          />
        ) : (
          <AboutScreen onOpenLicenses={() => setSubRoute('LICENSES')} />
        )}
      </View>
    ),
    [],
  );

  return (
    <View style={styles.root}>
      {Platform.OS === 'ios' ? (
        <NativeTabs active={tab} onSelect={onSelectTab} renderScene={renderScene} />
      ) : (
        <>
          {/* Home stays mounted so the map keeps its camera and loaded tiles. */}
          <MainScreen />
          {tab === 'settings' ? (
            <View style={styles.tabOverlay}>
              <SettingsScreen
                onOpenDebug={() => setSubRoute('DEBUG')}
                onOpenSplitTunneling={() => setSubRoute('SPLIT_TUNNELING')}
              />
            </View>
          ) : null}
          {tab === 'about' ? (
            <View style={styles.tabOverlay}>
              <AboutScreen onOpenLicenses={() => setSubRoute('LICENSES')} />
            </View>
          ) : null}
          <TabBar active={tab} onSelect={onSelectTab} />
        </>
      )}
      {subScreen != null ? <View style={styles.subOverlay}>{subScreen}</View> : null}
      {update.tier === 'blocked' ? (
        // Verified-manifest kill switch: covers everything including the tab bar. Hardware back
        // keeps its normal behaviour underneath (worst case it exits the app — that's not a
        // bypass); "Continue anyway" on the screen is the sanctioned way past it.
        <View style={styles.subOverlay}>
          <UpdateRequiredScreen />
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
  },
  scene: {
    flex: 1,
    backgroundColor: palette.screen,
  },
  tabOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: palette.screen,
  },
  subOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: palette.screen,
  },
});

export default App;
