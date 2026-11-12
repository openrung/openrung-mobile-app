import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Text } from 'react-native';

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import { DesktopTunnelModeSection } from '../../src/components/DesktopTunnelModeSection';
import type {
  DesktopCaptureMode,
  DesktopTunnelMode,
  OpenRungDesktopModule,
} from '../../src/native/OpenRungDesktop';

const PROXY_ROWS = 'local proxy rows';

/** A host whose mode follows setTunnelMode, unless `setError` makes it refuse. */
function desktopHost(
  initial: Partial<DesktopTunnelMode> = {},
  setError?: Error,
): OpenRungDesktopModule & { setTunnelMode: jest.Mock } {
  let current: DesktopTunnelMode = {
    mode: 'proxy',
    available: true,
    requiresRestart: false,
    ...initial,
  };
  return {
    appVersion: '9.9.9',
    getProxyInfo: jest.fn(),
    copyText: jest.fn(async () => undefined),
    getTunnelMode: jest.fn(async () => current),
    setTunnelMode: jest.fn(async (mode: DesktopCaptureMode) => {
      if (setError != null) {
        throw setError;
      }
      current = { ...current, mode };
    }),
  };
}

async function render(
  desktop: OpenRungDesktopModule,
  isIdle: boolean = true,
): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(
      <DesktopTunnelModeSection desktop={desktop} isIdle={isIdle}>
        <Text>{PROXY_ROWS}</Text>
      </DesktopTunnelModeSection>,
    );
  });
  return tree!;
}

function texts(tree: ReactTestRenderer.ReactTestRenderer): string[] {
  return tree.root.findAllByType(Text).map(node => String(node.props.children));
}

function modeSwitch(tree: ReactTestRenderer.ReactTestRenderer) {
  return tree.root.findAll(node => node.props.accessibilityRole === 'switch')[0];
}

async function press(node: ReactTestRenderer.ReactTestInstance): Promise<void> {
  await ReactTestRenderer.act(async () => {
    node.props.onPress();
  });
}

describe('DesktopTunnelModeSection', () => {
  it('offers no switch where the host cannot run TUN mode', async () => {
    const tree = await render(desktopHost({ available: false }));
    expect(modeSwitch(tree)).toBeUndefined();
    expect(texts(tree)).toEqual([PROXY_ROWS]);
  });

  it('offers no switch on a host that predates the capture mode', async () => {
    const olderHost: OpenRungDesktopModule = {
      appVersion: '9.9.9',
      getProxyInfo: jest.fn(),
      copyText: jest.fn(async () => undefined),
    };
    const tree = await render(olderHost);
    expect(modeSwitch(tree)).toBeUndefined();
    expect(texts(tree)).toEqual([PROXY_ROWS]);
  });

  it('warns that turning it on restarts the client when the host says so', async () => {
    const plain = await render(desktopHost());
    expect(texts(plain)).toContain(
      'Off. Only apps that use the system proxy go through OpenRung.',
    );
    const restarting = await render(desktopHost({ requiresRestart: true }));
    expect(texts(restarting)).toContain(
      'Off. Only apps that use the system proxy go through OpenRung. ' +
        'Turning it on restarts OpenRung with administrator rights.',
    );
  });

  it('switches the mode and drops the local proxy rows in TUN mode', async () => {
    const desktop = desktopHost();
    const tree = await render(desktop);
    expect(texts(tree)).toContain(PROXY_ROWS);

    await press(modeSwitch(tree));
    expect(desktop.setTunnelMode).toHaveBeenCalledWith('tun');
    expect(modeSwitch(tree).props.accessibilityState.checked).toBe(true);
    expect(texts(tree)).toContain('On. All traffic from this device goes through OpenRung.');
    expect(texts(tree)).not.toContain(PROXY_ROWS);

    await press(modeSwitch(tree));
    expect(desktop.setTunnelMode).toHaveBeenLastCalledWith('proxy');
    expect(texts(tree)).toContain(PROXY_ROWS);
  });

  it('shows why the host refused and stays in proxy mode', async () => {
    const tree = await render(
      desktopHost({ requiresRestart: true }, new Error('the Windows prompt was declined')),
    );
    await press(modeSwitch(tree));
    expect(texts(tree)).toContain('the Windows prompt was declined');
    expect(modeSwitch(tree).props.accessibilityState.checked).toBe(false);
    expect(texts(tree)).toContain(PROXY_ROWS);
  });

  it('locks the switch while a tunnel is up', async () => {
    const tree = await render(desktopHost(), false);
    expect(modeSwitch(tree).props.disabled).toBe(true);
    expect(texts(tree)).toContain('Disconnect to change the mode.');
  });
});
