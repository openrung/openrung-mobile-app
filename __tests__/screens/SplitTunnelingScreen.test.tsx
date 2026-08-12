import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Text } from 'react-native';

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

// Jest's react-native preset resolves Platform.OS to 'ios', so the APPS section stays hidden
// unless a test flips this flag (isAppListAvailable is false off-Android anyway).
jest.mock('../../src/native/OpenRungAppList', () => ({
  isAppListAvailable: false,
  getInstalledApps: jest.fn(async () => []),
}));

// Which country presets a fresh install starts with depends on where the device is (Intl time
// zone), so pin it: this suite renders the screen from a device outside Iran and China.
jest.mock('../../src/model/splitTunnelDefaults', () => ({
  defaultBypassCountries: () => [],
}));

// The store's debounced push goes through the bridge; mocking it keeps the suite off the
// scripted simulator (its reconnect walk would mutate the mirrored native state).
jest.mock('../../src/native/OpenRungVpn', () => ({
  OpenRungVpn: {
    setSplitTunnelConfig: jest.fn(async () => {}),
  },
}));

import { TerminalSwitch } from '../../src/components/TerminalSwitch';
import { SplitTunnelingScreen } from '../../src/screens/SplitTunnelingScreen';
import { getSnapshot, resetStoreForTests, setSplitTunnel } from '../../src/state/store';

async function renderScreen(): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(<SplitTunnelingScreen onBack={jest.fn()} />);
  });
  return tree!;
}

/** The screen's switches in render order: master, then LAN / ir / cn. */
function switches(
  tree: ReactTestRenderer.ReactTestRenderer,
): ReactTestRenderer.ReactTestInstance[] {
  return tree.root.findAllByType(TerminalSwitch);
}

async function unmount(tree: ReactTestRenderer.ReactTestRenderer): Promise<void> {
  await ReactTestRenderer.act(async () => {
    tree.unmount();
  });
}

beforeEach(() => {
  resetStoreForTests();
});

afterEach(() => {
  // Clears the pending debounced native push so no timer outlives the test.
  resetStoreForTests();
});

describe('SplitTunnelingScreen', () => {
  it('renders the master toggle and the BYPASS preset rows', async () => {
    const tree = await renderScreen();
    const labels = tree.root
      .findAllByType(Text)
      .map(text => text.props.children)
      .filter((label): label is string => typeof label === 'string');

    expect(labels).toContain('Split tunneling');
    expect(labels.indexOf('BYPASS')).toBeLessThan(labels.indexOf('Local network'));
    expect(labels).toContain('Iranian sites & apps');
    expect(labels).toContain('Chinese sites & apps');
    expect(labels).toContain(
      'changes apply immediately; the tunnel reconnects for a few seconds.',
    );
    await unmount(tree);
  });

  it('starts with the local-network preset on and disables the bypass rows when the master is turned off', async () => {
    const tree = await renderScreen();
    const [master, lan, ...countryRows] = switches(tree);

    expect(master.props.disabled).toBeUndefined();
    expect(master.props.value).toBe(true);
    // On a device outside Iran and China the country presets start off: geosite-cn carries
    // globally common hosts, so bypassing it there would leak ordinary page loads.
    expect(lan.props.value).toBe(true);
    expect(countryRows).toHaveLength(2);
    expect(countryRows.every(row => row.props.value === false)).toBe(true);
    expect([lan, ...countryRows].every(row => row.props.disabled === false)).toBe(true);

    await ReactTestRenderer.act(async () => {
      master.props.onChange(false);
    });

    expect(
      switches(tree)
        .slice(1)
        .every(row => row.props.disabled === true),
    ).toBe(true);
    await unmount(tree);
  });

  it('toggling the Iranian preset updates the store (normalized ir,cn order)', async () => {
    setSplitTunnel({ enabled: true, bypassCountries: ['cn'] });
    const tree = await renderScreen();
    const [, , iran] = switches(tree);

    expect(iran.props.value).toBe(false);
    await ReactTestRenderer.act(async () => {
      iran.props.onChange(true);
    });

    expect(getSnapshot().splitTunnel.bypassCountries).toEqual(['ir', 'cn']);
    await unmount(tree);
  });

  it('hides the APPS section when the app-list module is unavailable', async () => {
    const tree = await renderScreen();
    const labels = tree.root
      .findAllByType(Text)
      .map(text => text.props.children)
      .filter((label): label is string => typeof label === 'string');

    expect(labels).not.toContain('APPS');
    expect(labels).not.toContain('Bypassed apps');
    await unmount(tree);
  });
});
