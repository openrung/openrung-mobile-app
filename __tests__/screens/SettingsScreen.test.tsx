import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Alert, Linking, Share, Text } from 'react-native';

const mockShareInstalledApk = jest.fn<Promise<void>, [string]>();

// Jest's react-native preset resolves Platform.OS to 'ios', so giving the config a TestFlight
// link is all it takes to make the iOS sharing row available.
jest.mock('../../src/config', () => {
  const actual = jest.requireActual('../../src/config');
  return {
    ...actual,
    AppConfig: {
      ...actual.AppConfig,
      TESTFLIGHT_URL: 'https://testflight.apple.com/join/TESTCODE',
    },
  };
});

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

describe('SettingsScreen iOS TestFlight sharing', () => {
  it('places TestFlight sharing in General and opens the system share sheet', async () => {
    const share = jest
      .spyOn(Share, 'share')
      .mockResolvedValue({ action: Share.sharedAction });
    const tree = await renderSettings();
    const labels = tree.root
      .findAllByType(Text)
      .map(text => text.props.children)
      .filter((label): label is string => typeof label === 'string');

    expect(labels.indexOf('GENERAL')).toBeLessThan(
      labels.indexOf('Share OpenRung'),
    );
    expect(labels.indexOf('Share OpenRung')).toBeLessThan(
      labels.indexOf('DIAGNOSTICS'),
    );

    await ReactTestRenderer.act(async () => {
      findButton(tree, 'Share OpenRung').props.onPress();
      await Promise.resolve();
    });

    expect(share).toHaveBeenCalledWith(
      {
        message: 'Join the OpenRung beta on TestFlight:',
        url: 'https://testflight.apple.com/join/TESTCODE',
      },
      { subject: 'Share OpenRung' },
    );
    share.mockRestore();
    await unmount(tree);
  });

  it('surfaces an alert when the share sheet cannot be opened', async () => {
    const share = jest
      .spyOn(Share, 'share')
      .mockRejectedValue(new Error('share sheet unavailable'));
    const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => {});
    const tree = await renderSettings();

    await ReactTestRenderer.act(async () => {
      findButton(tree, 'Share OpenRung').props.onPress();
      await Promise.resolve();
    });

    expect(alert).toHaveBeenCalledWith(
      'Unable to share OpenRung',
      'The TestFlight link could not be shared. Try again.',
    );
    share.mockRestore();
    alert.mockRestore();
    await unmount(tree);
  });
});

describe('AboutScreen links', () => {
  it('opens the privacy policy from the About tab', async () => {
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(undefined);
    let tree: ReactTestRenderer.ReactTestRenderer | undefined;
    await ReactTestRenderer.act(async () => {
      tree = ReactTestRenderer.create(
        <AboutScreen onOpenLicenses={jest.fn()} />,
      );
    });

    await ReactTestRenderer.act(async () => {
      findButton(tree!, 'Privacy policy').props.onPress();
      await Promise.resolve();
    });

    expect(openURL).toHaveBeenCalledWith('https://www.openrung.org/privacy');
    openURL.mockRestore();
    await unmount(tree!);
  });
});
