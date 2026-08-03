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

import { ConnectCard } from '../../src/components/ConnectCard';
import type { ConnectCardProps } from '../../src/components/ConnectCard';

async function renderTexts(props: Partial<ConnectCardProps> = {}): Promise<string[]> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(
      <ConnectCard
        status="connected"
        relayName="proud-falcon"
        relayClass={null}
        isConnected
        isWorking={false}
        onToggle={jest.fn()}
        {...props}
      />,
    );
  });
  const text = tree!.root
    .findAllByType(Text)
    .flatMap(node => node.props.children)
    .filter((value): value is string => typeof value === 'string');
  await ReactTestRenderer.act(async () => {
    tree!.unmount();
  });
  return text;
}

describe('ConnectCard', () => {
  it('shows the connected relay name without a traffic-route footer', async () => {
    const text = await renderTexts();
    expect(text).toContain('proud-falcon');
    expect(text).not.toContain('traffic route: device -> OpenRung VPN -> relay');
  });

  it('shows the relay-class badge while connected: foundation renders OFFICIAL', async () => {
    const text = await renderTexts({ relayClass: 'foundation' });
    expect(text).toContain('proud-falcon');
    expect(text).toContain('OFFICIAL');
    expect(text).not.toContain('VOLUNTEER');
  });

  it('shows the relay-class badge while connected: volunteer renders VOLUNTEER', async () => {
    const text = await renderTexts({ relayClass: 'volunteer' });
    expect(text).toContain('VOLUNTEER');
    expect(text).not.toContain('OFFICIAL');
  });

  it('renders no badge when the class is unknown (stale native build)', async () => {
    const text = await renderTexts({ relayClass: null });
    expect(text).not.toContain('OFFICIAL');
    expect(text).not.toContain('VOLUNTEER');
  });

  it('renders no badge while disconnected even if a class is passed', async () => {
    const text = await renderTexts({
      status: 'disconnected',
      relayName: null,
      relayClass: 'volunteer',
      isConnected: false,
    });
    expect(text).not.toContain('VOLUNTEER');
  });
});
