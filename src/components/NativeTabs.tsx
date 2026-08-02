/**
 * iOS-only bottom tabs backed by the system TabView (react-native-bottom-tabs)
 * so the bar is the real native one: Liquid Glass with the press-follow
 * indicator on iOS 26+, classic translucent UITabBar on older iOS. Scenes are
 * kept alive by the native tab controller, so the home map keeps its camera
 * and tiles across tab switches. Android keeps the custom JS TabBar.
 */
import React, { useCallback, useMemo } from 'react';
import TabView, { type AppleIcon } from 'react-native-bottom-tabs';

import { useStrings } from '../i18n';
import { monoFont, palette } from '../theme';
import type { AppTab } from './TabBar';

const TAB_ORDER: AppTab[] = ['home', 'settings', 'about'];

const ICONS: Record<AppTab, AppleIcon> = {
  home: { sfSymbol: 'house' },
  settings: { sfSymbol: 'slider.horizontal.3' },
  about: { sfSymbol: 'info.circle' },
};

const TAB_LABEL_STYLE = { fontFamily: monoFont };

export interface NativeTabsProps {
  active: AppTab;
  onSelect: (tab: AppTab) => void;
  renderScene: (tab: AppTab) => React.ReactNode;
}

/** Memoized (with stable prop objects) so re-renders above it don't push fresh props to the
 * native tab controller on every pass. */
export const NativeTabs = React.memo(function NativeTabsComponent({
  active,
  onSelect,
  renderScene,
}: NativeTabsProps): React.JSX.Element {
  const s = useStrings();

  const routes = useMemo(() => {
    const titles: Record<AppTab, string> = {
      home: s.tabHome,
      settings: s.tabSettings,
      about: s.tabAbout,
    };
    return TAB_ORDER.map(tab => ({ key: tab, title: titles[tab], focusedIcon: ICONS[tab] }));
  }, [s]);

  const navigationState = useMemo(
    () => ({ index: TAB_ORDER.indexOf(active), routes }),
    [active, routes],
  );

  const onIndexChange = useCallback((index: number) => onSelect(TAB_ORDER[index]), [onSelect]);

  const renderRoute = useCallback(
    ({ route }: { route: { key: string } }) => renderScene(route.key as AppTab),
    [renderScene],
  );

  return (
    <TabView
      navigationState={navigationState}
      onIndexChange={onIndexChange}
      renderScene={renderRoute}
      tabBarActiveTintColor={palette.terminalGreen}
      tabBarInactiveTintColor={palette.dimText}
      tabLabelStyle={TAB_LABEL_STYLE}
      hapticFeedbackEnabled
    />
  );
});
