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
            relayId: 'relay_jp1',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
        ]}
        liveRelayIds={new Set(['relay_jp1'])}
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

  it('pins the exact relay when pressed', async () => {
    const onPress = jest.fn();
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            relayId: 'relay_jp1',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
        ]}
        liveRelayIds={new Set(['relay_jp1'])}
        onPress={onPress}
      />,
    );

    await ReactTestRenderer.act(async () => {
      tree.root.findByProps({ accessibilityRole: 'button' }).props.onPress();
    });

    expect(onPress).toHaveBeenCalledWith('relay_jp1', 'JP');
  });

  it('keeps different relays from the same country distinct', async () => {
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            relayId: 'relay_jp1',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
          {
            countryCode: 'JP',
            relayId: 'relay_jp2',
            label: 'Tokyo, Japan',
            relayName: 'swift-harbor',
            latitude: 36.2,
            longitude: 138.25,
          },
        ]}
        liveRelayIds={new Set(['relay_jp1', 'relay_jp2'])}
        onPress={jest.fn()}
      />,
    );

    const text = tree.root
      .findAllByType(Text)
      .flatMap(node => node.props.children)
      .filter((value): value is string => typeof value === 'string');
    expect(text).toEqual(expect.arrayContaining(['proud-falcon', 'swift-harbor']));
  });

  it('hides legacy entries without an exact relay id', async () => {
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
        liveRelayIds={new Set(['relay_jp1'])}
        onPress={jest.fn()}
      />,
    );

    expect(tree.toJSON()).toBeNull();
  });

  it('hides relays the broker no longer lists', async () => {
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            relayId: 'relay_jp1',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
          {
            countryCode: 'DE',
            relayId: 'relay_de9',
            label: 'Berlin, Germany',
            relayName: 'retired-otter',
            latitude: 52.5,
            longitude: 13.4,
          },
        ]}
        liveRelayIds={new Set(['relay_jp1'])}
        onPress={jest.fn()}
      />,
    );

    const text = tree.root
      .findAllByType(Text)
      .flatMap(node => node.props.children)
      .filter((value): value is string => typeof value === 'string');
    expect(text).toContain('proud-falcon');
    expect(text).not.toContain('retired-otter');
  });

  it('hides the whole row when no recent relay is still listed', async () => {
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            relayId: 'relay_jp1',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
        ]}
        liveRelayIds={new Set(['relay_de9'])}
        onPress={jest.fn()}
      />,
    );

    expect(tree.toJSON()).toBeNull();
  });

  it('keeps every pinned entry while the directory is unavailable', async () => {
    // A failed or in-flight directory load is not evidence a relay is gone — hiding the row then
    // would empty it exactly when the user most needs a known-good relay.
    const tree = await render(
      <RecentsSection
        recents={[
          {
            countryCode: 'JP',
            relayId: 'relay_jp1',
            label: 'Tokyo, Japan',
            relayName: 'proud-falcon',
            latitude: 36.2,
            longitude: 138.25,
          },
          {
            countryCode: 'DE',
            relayId: 'relay_de9',
            label: 'Berlin, Germany',
            relayName: 'retired-otter',
            latitude: 52.5,
            longitude: 13.4,
          },
        ]}
        liveRelayIds={null}
        onPress={jest.fn()}
      />,
    );

    const text = tree.root
      .findAllByType(Text)
      .flatMap(node => node.props.children)
      .filter((value): value is string => typeof value === 'string');
    expect(text).toEqual(expect.arrayContaining(['proud-falcon', 'retired-otter']));
  });
});
