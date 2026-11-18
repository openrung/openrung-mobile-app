/**
 * Bottom tab bar: Home / Settings / About. Dark translucent glass with a
 * hairline top border, so the full-screen map stays faintly visible beneath
 * it on the home tab. The active tab gets the terminal-green tint plus a thin
 * glowing indicator segment along the top edge — a HUD accent rather than a
 * Material pill, to match the terminal theme.
 *
 * In the wide layout (desktop windows, tablets) the same tabs run down a
 * navigation rail on the left edge instead, with the indicator along the
 * item's outer edge.
 */
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useStrings } from '../i18n';
import { useWideLayout } from '../layout';
import { monoFont, palette, tokens } from '../theme';
import { HomeIcon, InfoIcon, SlidersIcon, type IconProps } from './Icons';

export type AppTab = 'home' | 'settings' | 'about';

export interface TabBarProps {
  active: AppTab;
  onSelect: (tab: AppTab) => void;
}

interface TabSpec {
  tab: AppTab;
  Icon: (props: IconProps) => React.JSX.Element;
  label: (s: ReturnType<typeof useStrings>) => string;
}

const TABS: TabSpec[] = [
  { tab: 'home', Icon: HomeIcon, label: s => s.tabHome },
  { tab: 'settings', Icon: SlidersIcon, label: s => s.tabSettings },
  { tab: 'about', Icon: InfoIcon, label: s => s.tabAbout },
];

export function TabBar({ active, onSelect }: TabBarProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const rail = useWideLayout();

  return (
    <View
      accessibilityRole="tablist"
      style={
        rail
          ? [
              styles.rail,
              {
                width: insets.left + tokens.navRailWidth,
                paddingTop: insets.top + 16,
                paddingBottom: insets.bottom,
                paddingLeft: insets.left,
              },
            ]
          : [styles.bar, { paddingBottom: insets.bottom }]
      }
    >
      {TABS.map(({ tab, Icon, label }) => {
        const isActive = tab === active;
        return (
          <Pressable
            key={tab}
            onPress={() => onSelect(tab)}
            // `hovered` is react-native-web's (desktop pointer); native never sets it.
            style={state => [
              rail ? styles.railItem : styles.item,
              (state as { hovered?: boolean }).hovered && !isActive && styles.itemHovered,
            ]}
            accessibilityRole="tab"
            accessibilityState={{ selected: isActive }}
            accessibilityLabel={label(s)}
          >
            {isActive ? <View style={rail ? styles.railIndicator : styles.indicator} /> : null}
            <TabContent Icon={Icon} label={label(s)} isActive={isActive} />
          </Pressable>
        );
      })}
    </View>
  );
}

function TabContent({
  Icon,
  label,
  isActive,
}: {
  Icon: TabSpec['Icon'];
  label: string;
  isActive: boolean;
}): React.JSX.Element {
  const tint = isActive ? palette.terminalGreen : palette.dimText;
  return (
    <>
      <Icon color={tint} size={22} />
      <Text
        style={[styles.label, { color: tint }, isActive && styles.labelActive]}
        numberOfLines={1}
      >
        {label}
      </Text>
    </>
  );
}

const styles = StyleSheet.create({
  bar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    backgroundColor: tokens.glassDense,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: tokens.glassBorder,
  },
  rail: {
    position: 'absolute',
    left: 0,
    top: 0,
    bottom: 0,
    gap: 4,
    backgroundColor: tokens.glassDense,
    borderRightWidth: StyleSheet.hairlineWidth,
    borderRightColor: tokens.glassBorder,
  },
  item: {
    flex: 1,
    height: tokens.tabBarHeight,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 4,
  },
  railItem: {
    height: 68,
    paddingHorizontal: 4,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  itemHovered: {
    backgroundColor: 'rgba(101, 245, 138, 0.06)',
  },
  indicator: {
    position: 'absolute',
    top: 0,
    width: 32,
    height: 2,
    borderRadius: 1,
    backgroundColor: palette.terminalGreen,
    shadowColor: tokens.glow,
    shadowOpacity: 1,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 0 },
  },
  railIndicator: {
    position: 'absolute',
    left: 0,
    width: 2,
    height: 32,
    borderRadius: 1,
    backgroundColor: palette.terminalGreen,
    shadowColor: tokens.glow,
    shadowOpacity: 1,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 0 },
  },
  label: {
    fontFamily: monoFont,
    fontSize: 10,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
  },
  labelActive: {
    fontWeight: 'bold',
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 8,
  },
});
