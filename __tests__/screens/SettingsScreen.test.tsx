import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Alert, Text } from 'react-native';

const mockShareInstalledApk = jest.fn<Promise<void>, [string]>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => {}),
    removeItem: jest.fn(async () => {}),
  },
}));

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, right: 0, bottom: 0, left: 0 }),
}));

jest.mock('../../src/state/useVpnState', () => ({
  useVpnState: () => ({ isConnected: false }),
}));

jest.mock('../../src/native/OpenRungApkShare', () => ({
  isApkShareAvailable: true,
  shareInstalledApk: (chooserTitle: string) =>
    mockShareInstalledApk(chooserTitle),
  apkShareErrorCode: (error: unknown) =>
    typeof error === 'object' && error != null && 'code' in error
      ? (error as { code: string }).code
      : null,
}));

import { AboutScreen } from '../../src/screens/AboutScreen';
import { SettingsScreen } from '../../src/screens/SettingsScreen';

async function renderSettings(): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(<SettingsScreen onOpenDebug={jest.fn()} />);
  });
  return tree!;
}

function findButton(
  tree: ReactTestRenderer.ReactTestRenderer,
  title: string,
): ReactTestRenderer.ReactTestInstance {
  return tree.root
    .findAll(node => typeof node.props.onPress === 'function')
    .find(node =>
      node.findAllByType(Text).some(text => text.props.children === title),
    )!;
}

async function unmount(
  tree: ReactTestRenderer.ReactTestRenderer,
): Promise<void> {
  await ReactTestRenderer.act(async () => {
    tree.unmount();
  });
}

describe('SettingsScreen Android APK sharing', () => {
  beforeEach(() => {
    mockShareInstalledApk.mockReset();
  });

  it('places offline sharing in General and opens the native share sheet', async () => {
    mockShareInstalledApk.mockResolvedValue(undefined);
    const tree = await renderSettings();
    const labels = tree.root
      .findAllByType(Text)
      .map(text => text.props.children)
      .filter((label): label is string => typeof label === 'string');

    expect(labels.indexOf('GENERAL')).toBeLessThan(
      labels.indexOf('Share OpenRung offline'),
    );
    expect(labels.indexOf('Share OpenRung offline')).toBeLessThan(
      labels.indexOf('DIAGNOSTICS'),
    );

    await ReactTestRenderer.act(async () => {
      findButton(tree, 'Share OpenRung offline').props.onPress();
      await Promise.resolve();
    });

    expect(mockShareInstalledApk).toHaveBeenCalledWith(
      'Share OpenRung offline',
    );
    await unmount(tree);
  });

  it('explains why a split install cannot be shared', async () => {
    mockShareInstalledApk.mockRejectedValue(
      Object.assign(new Error('split install'), {
        code: 'E_SPLIT_APK_INSTALL',
      }),
    );
    const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => {});
    const tree = await renderSettings();

    await ReactTestRenderer.act(async () => {
      findButton(tree, 'Share OpenRung offline').props.onPress();
      await Promise.resolve();
    });

    expect(alert).toHaveBeenCalledWith(
      'Unable to share OpenRung',
      'This copy was installed as multiple APK files and cannot be shared safely. Install the standalone OpenRung APK to use offline sharing.',
    );
    alert.mockRestore();
    await unmount(tree);
  });

  it('does not leave a duplicate sharing action on the About tab', async () => {
    let tree: ReactTestRenderer.ReactTestRenderer | undefined;
    await ReactTestRenderer.act(async () => {
      tree = ReactTestRenderer.create(
        <AboutScreen onOpenLicenses={jest.fn()} />,
      );
    });

    const hasShareAction = tree!.root
      .findAllByType(Text)
      .some(text => text.props.children === 'Share OpenRung offline');
    expect(hasShareAction).toBe(false);
    await unmount(tree!);
  });
});
