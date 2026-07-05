/**
 * MAP/LIST segmented toggle for the home-screen relay directory. A compact
 * glass pill with two segments; the active one lights up terminal-green over
 * a soft green fill while the inactive one stays dim — the same
 * active/inactive language as the tab bar, shrunk to chip scale so it can
 * float over the map.
 */
import React from 'react';
import { Pressable, StyleSheet, StyleProp, Text, View, ViewStyle } from 'react-native';

import { useStrings, type Strings } from '../i18n';
import type { HomeViewMode } from '../model/exitNode';
import { monoFont, palette, tokens } from '../theme';
import { ListIcon, MapIcon, type IconProps } from './Icons';

export interface ViewModeToggleProps {
  mode: HomeViewMode;
  onChange: (mode: HomeViewMode) => void;
  style?: StyleProp<ViewStyle>;
}

interface SegmentSpec {
  mode: HomeViewMode;
  Icon: (props: IconProps) => React.JSX.Element;
  label: (s: Strings) => string;
}

const SEGMENTS: SegmentSpec[] = [
  { mode: 'map', Icon: MapIcon, label: s => s.viewToggleMap },
  { mode: 'list', Icon: ListIcon, label: s => s.viewToggleList },
];

export function ViewModeToggle({ mode, onChange, style }: ViewModeToggleProps): React.JSX.Element {
  const s = useStrings();

  return (
    <View style={[styles.container, style]}>
      {SEGMENTS.map(({ mode: segment, Icon, label }) => {
        const isActive = segment === mode;
        const tint = isActive ? palette.terminalGreen : palette.dimText;
        return (
          <Pressable
            key={segment}
            onPress={() => {
              if (!isActive) {
                onChange(segment);
              }
            }}
            style={[styles.segment, isActive && styles.segmentActive]}
            accessibilityRole="tab"
            accessibilityState={{ selected: isActive }}
            accessibilityLabel={label(s)}
          >
            <Icon color={tint} size={13} strokeWidth={2.2} />
            <Text style={[styles.label, { color: tint }, isActive && styles.labelActive]}>
              {label(s).toUpperCase()}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignSelf: 'center',
    borderRadius: tokens.radiusSm,
    backgroundColor: tokens.glass,
    borderWidth: 1,
    borderColor: tokens.glassBorder,
    padding: 3,
    gap: 3,
  },
  segment: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    borderRadius: tokens.radiusSm - 3,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  segmentActive: {
    backgroundColor: 'rgba(101, 245, 138, 0.12)',
  },
  label: {
    fontFamily: monoFont,
    fontSize: 10,
    letterSpacing: 1.5,
  },
  labelActive: {
    fontWeight: 'bold',
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 8,
  },
});
