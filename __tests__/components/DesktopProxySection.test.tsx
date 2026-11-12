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

import { DesktopProxySection } from '../../src/components/DesktopProxySection';
import type { DesktopProxyInfo, OpenRungDesktopModule } from '../../src/native/OpenRungDesktop';

const INFO: DesktopProxyInfo = {
  endpoint: '127.0.0.1:18080',
  persistenceWarning: null,
  shellIntegration: true,
  shellIntegrationError: null,
  enableCommand: 'source enable.sh',
  disableCommand: 'source disable.sh',
};

function desktopHost(info: Partial<DesktopProxyInfo> | Error = {}): OpenRungDesktopModule {
  return {
    appVersion: '9.9.9',
    getProxyInfo: jest.fn(async () => {
      if (info instanceof Error) {
        throw info;
      }
      return { ...INFO, ...info };
    }),
    copyText: jest.fn(async () => undefined),
    getTunnelMode: jest.fn(async () => ({
      mode: 'proxy' as const,
      available: false,
      requiresRestart: false,
    })),
    setTunnelMode: jest.fn(async () => undefined),
  };
}

async function render(
  desktop: OpenRungDesktopModule,
  isConnected: boolean,
): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(
      <DesktopProxySection desktop={desktop} isConnected={isConnected} />,
    );
  });
  return tree!;
}

function texts(tree: ReactTestRenderer.ReactTestRenderer): string[] {
  return tree.root.findAllByType(Text).map(node => String(node.props.children));
}

/** The copy buttons in render order (outermost node of each: it carries the props under test). */
function copyButtons(tree: ReactTestRenderer.ReactTestRenderer) {
  const isButton = (node: ReactTestRenderer.ReactTestInstance) =>
    node.props.accessibilityRole === 'button' && typeof node.props.onPress === 'function';
  return tree.root.findAll(node => isButton(node) && (node.parent == null || !isButton(node.parent)));
}

describe('DesktopProxySection', () => {
  it('shows the endpoint and whether it is serving', async () => {
    const idle = await render(desktopHost(), false);
    expect(texts(idle)).toContain('127.0.0.1:18080 · available while connected');
    const connected = await render(desktopHost(), true);
    expect(texts(connected)).toContain('127.0.0.1:18080 · available now');
  });

  it('copies the endpoint and both shell commands through the host', async () => {
    const desktop = desktopHost();
    const tree = await render(desktop, true);
    const [endpoint, enable, restore] = copyButtons(tree);

    await ReactTestRenderer.act(async () => {
      endpoint.props.onPress();
    });
    expect(desktop.copyText).toHaveBeenLastCalledWith('127.0.0.1:18080');
    expect(texts(tree).filter(text => text === 'Copied')).toHaveLength(1);

    await ReactTestRenderer.act(async () => {
      enable.props.onPress();
    });
    expect(desktop.copyText).toHaveBeenLastCalledWith('source enable.sh');
    await ReactTestRenderer.act(async () => {
      restore.props.onPress();
    });
    expect(desktop.copyText).toHaveBeenLastCalledWith('source disable.sh');
    tree.unmount();
  });

  it('withholds the enable command until connected, but never the restore command', async () => {
    const tree = await render(desktopHost(), false);
    const [, enable, restore] = copyButtons(tree);
    expect(enable.props.disabled).toBe(true);
    expect(restore.props.disabled).not.toBe(true);
    expect(texts(tree)).toContain('Connect OpenRung before enabling this shell.');
  });

  it('reports host problems in place of what they affect', async () => {
    const tree = await render(
      desktopHost({
        persistenceWarning: 'port may change',
        shellIntegrationError: 'helper not written',
      }),
      true,
    );
    expect(texts(tree)).toEqual(expect.arrayContaining(['port may change', 'helper not written']));
    // Only the endpoint stays copyable: there are no shell commands to hand out.
    expect(copyButtons(tree)).toHaveLength(1);
  });

  it('omits the shell rows on a system without shell integration', async () => {
    const tree = await render(desktopHost({ shellIntegration: false }), true);
    expect(copyButtons(tree)).toHaveLength(1);
  });

  it('shows why the endpoint could not be resolved', async () => {
    const tree = await render(desktopHost(new Error('no free port')), true);
    expect(texts(tree)).toContain('no free port');
    expect(copyButtons(tree)).toHaveLength(0);
  });
});
