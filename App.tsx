/**
 * OpenRung mobile app root. Three bottom tabs (Home / Settings / About us)
 * over a plain state machine — no nav library, screens swap instantly. The
 * home screen (full-screen map) stays mounted underneath the other tabs so
 * the MapLibre view keeps its camera/tiles across tab switches; Settings and
 * About render as opaque overlays above it. Deep screens (debug console,
 * licenses, license full text) push over everything including the tab bar,
 * with hardware back mapped exactly like their in-header back arrows:
 * LICENSE_TEXT -> LICENSES -> ABOUT, DEBUG -> SETTINGS, any tab -> HOME,
 * HOME -> system default (exit).
 */
import React, { useCallback, useEffect, useState } from 'react';
import { BackHandler, StatusBar, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { TabBar, type AppTab } from './src/components/TabBar';
import { LanguageProvider } from './src/i18n';
import { hydratePreferences } from './src/state/store';
import { useAutoConnect } from './src/state/useAutoConnect';
import { AboutScreen } from './src/screens/AboutScreen';
import { DebugScreen } from './src/screens/DebugScreen';
import { LicenseTextScreen } from './src/screens/LicenseTextScreen';
import { LicensesScreen } from './src/screens/LicensesScreen';
import { MainScreen } from './src/screens/MainScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import { SplitTunnelScreen } from './src/screens/SplitTunnelScreen';
import { palette } from './src/theme';

/** Screens pushed over the tabs (each has its own back arrow). */
type SubRoute = 'DEBUG' | 'LICENSES' | 'LICENSE_TEXT' | 'SPLIT_TUNNEL' | null;

function App(): React.JSX.Element {
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

  // Load persisted favorites + connection prefs once; auto-connect decides after hydration.
  useEffect(() => {
    hydratePreferences();
  }, []);
  useAutoConnect();

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
    case 'SPLIT_TUNNEL':
      subScreen = <SplitTunnelScreen onBack={() => setSubRoute(null)} />;
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

  return (
    <View style={styles.root}>
      {/* Home stays mounted so the map keeps its camera and loaded tiles. */}
      <MainScreen />
      {tab === 'settings' ? (
        <View style={styles.tabOverlay}>
          <SettingsScreen
            onOpenDebug={() => setSubRoute('DEBUG')}
            onOpenSplitTunnel={() => setSubRoute('SPLIT_TUNNEL')}
          />
        </View>
      ) : null}
      {tab === 'about' ? (
        <View style={styles.tabOverlay}>
          <AboutScreen onOpenLicenses={() => setSubRoute('LICENSES')} />
        </View>
      ) : null}
      <TabBar active={tab} onSelect={onSelectTab} />
      {subScreen != null ? <View style={styles.subOverlay}>{subScreen}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
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
