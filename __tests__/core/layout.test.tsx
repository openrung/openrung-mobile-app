/**
 * Window-adaptive layout helpers: tab scenes must pad for the tab bar on the edge the
 * platform puts it, and every screen must honor side insets (iPhone Duo inner display rail).
 */
import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Platform, Text } from 'react-native';

const mockInsets = { top: 47, right: 0, bottom: 34, left: 84 };
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => mockInsets,
}));

import { edgePadding, useTabSceneInsets } from '../../src/layout';
import { tokens } from '../../src/theme';

function Probe({ onInsets }: { onInsets: (insets: object) => void }): React.JSX.Element {
  onInsets(useTabSceneInsets());
  return <Text>probe</Text>;
}

async function readInsets(): Promise<object> {
  let seen: object | null = null;
  await ReactTestRenderer.act(async () => {
    ReactTestRenderer.create(<Probe onInsets={insets => (seen = insets)} />);
  });
  return seen!;
}

describe('useTabSceneInsets', () => {
  const originalOS = Platform.OS;
  afterEach(() => {
    Platform.OS = originalOS;
  });

  it('passes the scene provider insets through on iOS (native bar already included)', async () => {
    Platform.OS = 'ios';
    expect(await readInsets()).toEqual(mockInsets);
  });

  it('adds the JS tab bar height below the safe area on Android', async () => {
    Platform.OS = 'android';
    expect(await readInsets()).toEqual({ ...mockInsets, bottom: 34 + tokens.tabBarHeight });
  });
});

describe('edgePadding', () => {
  it('pads each side independently: vertical gap on top/bottom, edge gutter plus inset on the sides', () => {
    expect(edgePadding(mockInsets, 20)).toEqual({
      paddingTop: 67,
      paddingBottom: 54,
      paddingLeft: 84 + tokens.edge,
      paddingRight: tokens.edge,
    });
  });
});
