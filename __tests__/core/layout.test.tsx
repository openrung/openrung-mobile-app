/**
 * Window-adaptive layout helpers: tab scenes must pad for the tab bar on the edge the
 * platform puts it (the bottom, or the leading rail in the wide layout), and every screen
 * must honor side insets (iPhone Duo inner display rail).
 */
import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Platform, Text } from 'react-native';

const mockInsets = { top: 47, right: 0, bottom: 34, left: 84 };
const mockFrame = { x: 0, y: 0, width: 390, height: 844 };
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => mockInsets,
  useSafeAreaFrame: () => mockFrame,
}));

import { edgePadding, homeSidePanelWidth, useTabSceneInsets } from '../../src/layout';
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
    mockFrame.width = 390;
  });

  it('passes the scene provider insets through on iOS (native bar already included)', async () => {
    Platform.OS = 'ios';
    expect(await readInsets()).toEqual(mockInsets);
  });

  it('adds the JS tab bar height below the safe area on Android', async () => {
    Platform.OS = 'android';
    expect(await readInsets()).toEqual({ ...mockInsets, bottom: 34 + tokens.tabBarHeight });
  });

  it('adds the navigation rail on the left instead in a wide window', async () => {
    Platform.OS = 'web';
    mockFrame.width = 1280;
    expect(await readInsets()).toEqual({ ...mockInsets, left: 84 + tokens.navRailWidth });
  });

  it('keeps passing the scene insets through on a wide iOS scene', async () => {
    Platform.OS = 'ios';
    mockFrame.width = 1280;
    expect(await readInsets()).toEqual(mockInsets);
  });
});

describe('homeSidePanelWidth', () => {
  it('grows with the window between its bounds', () => {
    expect(homeSidePanelWidth(880)).toBe(380);
    expect(homeSidePanelWidth(1280)).toBe(435);
    expect(homeSidePanelWidth(2560)).toBe(460);
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
