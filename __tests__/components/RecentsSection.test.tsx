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

import { RecentsSection } from '../../src/components/RecentsSection';

async function render(element: React.ReactElement): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(element);
  });
  return tree!;
}

describe('RecentsSection', () => {
  it('shows the relay name instead of the saved city and country label', async () => {
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
        ]}
        onPress={jest.fn()}
      />,
    );

    const text = tree.root
      .findAllByType(Text)
      .flatMap(node => node.props.children)
      .filter((value): value is string => typeof value === 'string');
    expect(text).toContain('proud-falcon');
    expect(text).not.toContain('Tokyo, Japan');
  });

  it('hides legacy location-only entries', async () => {
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            label: 'Tokyo, Japan',
            latitude: 36.2,
            longitude: 138.25,
          },
        ]}
        onPress={jest.fn()}
      />,
    );

    expect(tree.toJSON()).toBeNull();
  });
});
