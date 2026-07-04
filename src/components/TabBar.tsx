/**
 * Bottom tab bar: Home / Settings / About. Dark translucent glass with a
 * hairline top border, so the full-screen map stays faintly visible beneath
 * it on the home tab. The active tab gets the terminal-green tint plus a thin
 * glowing indicator segment along the top edge — a HUD accent rather than a
 * Material pill, to match the terminal theme.
 */
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useStrings } from '../i18n';
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

  return (
    <View style={[styles.bar, { paddingBottom: insets.bottom }]}>
      {TABS.map(({ tab, Icon, label }) => {
        const isActive = tab === active;
        const tint = isActive ? palette.terminalGreen : palette.dimText;
        return (
          <Pressable
            key={tab}
            onPress={() => onSelect(tab)}
            style={styles.item}
            accessibilityRole="tab"
            accessibilityState={{ selected: isActive }}
            accessibilityLabel={label(s)}
          >
            {isActive ? <View style={styles.indicator} /> : null}
            <Icon color={tint} size={22} />
            <Text style={[styles.label, { color: tint }, isActive && styles.labelActive]}>
              {label(s)}
            </Text>
          </Pressable>
        );
      })}
    </View>
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
  item: {
    flex: 1,
    height: tokens.tabBarHeight,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 4,
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
