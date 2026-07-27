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

describe('ConnectCard', () => {
  it('shows the connected relay name without a traffic-route footer', async () => {
    let tree: ReactTestRenderer.ReactTestRenderer | undefined;
    await ReactTestRenderer.act(async () => {
      tree = ReactTestRenderer.create(
        <ConnectCard
          status="connected"
          relayName="proud-falcon"
          isConnected
          isWorking={false}
          onToggle={jest.fn()}
        />,
      );
    });

    const text = tree!.root
      .findAllByType(Text)
      .flatMap(node => node.props.children)
      .filter((value): value is string => typeof value === 'string');
    expect(text).toContain('proud-falcon');
    expect(text).not.toContain('traffic route: device -> OpenRung VPN -> relay');

    await ReactTestRenderer.act(async () => {
      tree!.unmount();
    });
  });
});
