/**
 * Home relay-directory list + view toggle behaviour:
 *  - RelayList sorts rows country-then-city; every location row expands into
 *    per-relay child rows (friendly labels) whose taps report the exact
 *    relay id — location rows themselves never connect;
 *  - the empty panel mirrors the status chip (loading / failed / no-nodes,
 *    the latter two tappable to retry);
 *  - ViewModeToggle reports the newly selected mode and ignores taps on the
 *    already-active segment.
 */
import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { ActivityIndicator, FlatList, Text } from 'react-native';

// Pulled in via RelayList -> i18n -> store; an in-memory stand-in keeps Jest off the native module.
jest.mock('@react-native-async-storage/async-storage', () => {
  const storage = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (key: string) => storage.get(key) ?? null),
      setItem: jest.fn(async (key: string, value: string) => {
        storage.set(key, value);
      }),
      removeItem: jest.fn(async (key: string) => {
        storage.delete(key);
      }),
    },
  };
});

jest.mock('react-native-svg', () => {
  const ReactActual = require('react');
  const { View } = require('react-native');
  const stub = (name: string) => {
    const Stub = ({ children, ...props }: { children?: React.ReactNode }) =>
      ReactActual.createElement(View, props, children);
    Stub.displayName = name;
    return Stub;
  };
  const Svg = stub('Svg');
  return {
    __esModule: true,
    default: Svg,
    Svg,
    Circle: stub('SvgCircle'),
    Line: stub('SvgLine'),
    Path: stub('SvgPath'),
  };
});

import { RelayList } from '../../src/components/RelayList';
import { ViewModeToggle } from '../../src/components/ViewModeToggle';
import type { ExitNodeRegion } from '../../src/model/exitNode';

const REGIONS: ExitNodeRegion[] = [
  {
    countryCode: 'JP',
    countryName: 'Japan',
    city: 'Tokyo',
    latitude: 35.6895,
    longitude: 139.6917,
    nodeCount: 2,
    relays: [
      { id: 'relay_jp1', label: 'proud-falcon' },
      { id: 'relay_jp2', label: null },
    ],
  },
  {
    countryCode: 'DE',
    countryName: 'Germany',
    city: 'Berlin',
    latitude: 52.52,
    longitude: 13.405,
    nodeCount: 1,
    relays: [{ id: 'relay_de1', label: 'zesty-tapir' }],
  },
  {
    countryCode: 'DE',
    countryName: 'Germany',
    city: null,
    latitude: 51.16,
    longitude: 10.45,
    nodeCount: 3,
    relays: [
      { id: 'relay_de2', label: 'a-relay' },
      { id: 'relay_de3', label: 'b-relay' },
      { id: 'relay_de4', label: 'c-relay' },
    ],
  },
];

async function render(element: React.ReactElement): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(element);
  });
  return tree!;
}

/**
 * The Pressable elements of the tree (RN wraps Pressable in memo/forwardRef,
 * so findAllByType can't see it): the instances that own an onPress prop.
 * Host views never receive onPress — Pressable consumes it — so this matches
 * exactly one instance per Pressable.
 */
function findPressables(tree: ReactTestRenderer.ReactTestRenderer): ReactTestRenderer.ReactTestInstance[] {
  return tree.root.findAll(node => typeof node.props.onPress === 'function');
}

describe('RelayList', () => {
  it('renders one row per region, sorted by country then city, each with a chevron', async () => {
    const tree = await render(
      <RelayList
        regions={REGIONS}
        directoryStatus="loaded"
        onRelayPress={jest.fn()}
        onRetry={jest.fn()}
      />,
    );
    const texts = tree.root
      .findAllByType(Text)
      .map(node => node.props.children)
      .filter(child => typeof child === 'string');
    // Country-only Germany ('' city) sorts before Berlin; Japan last.
    expect(texts).toEqual([
      '🇩🇪',
      'Germany',
      '3 relays',
      '▸',
      '🇩🇪',
      'Berlin, Germany',
      '1 relay',
      '▸',
      '🇯🇵',
      'Tokyo, Japan',
      '2 relays',
      '▸',
    ]);
    tree.unmount();
  });

  it('expands single-relay rows the same way and reports the tapped relay id', async () => {
    const onRelayPress = jest.fn();
    const tree = await render(
      <RelayList
        regions={REGIONS}
        directoryStatus="loaded"
        onRelayPress={onRelayPress}
        onRetry={jest.fn()}
      />,
    );
    await ReactTestRenderer.act(async () => {
      findPressables(tree)[1].props.onPress(); // Berlin, Germany (1 relay) -> expand
    });
    expect(onRelayPress).not.toHaveBeenCalled();

    const rows = findPressables(tree);
    expect(rows).toHaveLength(4); // 3 regions + 1 expanded child
    await ReactTestRenderer.act(async () => {
      rows[2].props.onPress(); // Berlin's only child: zesty-tapir
    });
    expect(onRelayPress).toHaveBeenCalledWith('relay_de1', 'DE');
    tree.unmount();
  });

  it('expands multi-relay rows into labelled per-relay rows and reports the tapped relay id', async () => {
    const onRelayPress = jest.fn();
    const tree = await render(
      <RelayList
        regions={REGIONS}
        directoryStatus="loaded"
        onRelayPress={onRelayPress}
        onRetry={jest.fn()}
      />,
    );
    await ReactTestRenderer.act(async () => {
      findPressables(tree)[2].props.onPress(); // Tokyo, Japan (2 relays) -> expand
    });

    const labels = tree.root
      .findAllByType(Text)
      .map(node => node.props.children)
      .filter(child => typeof child === 'string');
    // Children in broker order under the Tokyo row; missing label falls back to the bare id.
    expect(labels).toContain('proud-falcon');
    expect(labels).toContain('jp2');
    expect(labels).toContain('▾');

    const rows = findPressables(tree);
    expect(rows).toHaveLength(5); // 3 regions + 2 expanded children
    await ReactTestRenderer.act(async () => {
      rows[4].props.onPress(); // second Tokyo child
    });
    expect(onRelayPress).toHaveBeenCalledWith('relay_jp2', 'JP');

    // Tapping the region again collapses its children.
    await ReactTestRenderer.act(async () => {
      findPressables(tree)[2].props.onPress();
    });
    expect(findPressables(tree)).toHaveLength(3);
    tree.unmount();
  });

  it('engages a directory re-fetch only when the pull passes the threshold', async () => {
    const onRetry = jest.fn();
    const tree = await render(
      <RelayList
        regions={REGIONS}
        directoryStatus="loaded"
        onRelayPress={jest.fn()}
        onRetry={onRetry}
        refreshing={false}
      />,
    );
    const list = tree.root.findByType(FlatList);
    // Dragging into overscroll reveals the easter-egg calligraphy (Sun
    // Yat-sen's testament), which doubles as the pull indicator.
    await ReactTestRenderer.act(async () => {
      list.props.onScroll({ nativeEvent: { contentOffset: { y: -40 } } });
    });
    tree.root.findByProps({ accessibilityLabel: '革命尚未成功，同志仍須努力 - 孫中山' });
    // A shallow drag — the kind an incidental overscroll produces — is ignored.
    await ReactTestRenderer.act(async () => {
      list.props.onScrollEndDrag({ nativeEvent: { contentOffset: { y: -40 } } });
    });
    expect(onRetry).not.toHaveBeenCalled();
    // Only a deliberate pull past the threshold fires the forced refresh.
    await ReactTestRenderer.act(async () => {
      list.props.onScrollEndDrag({ nativeEvent: { contentOffset: { y: -160 } } });
    });
    expect(onRetry).toHaveBeenCalledTimes(1);
    tree.unmount();
  });

  it('shows a spinner while refreshing and ignores further pulls', async () => {
    const onRetry = jest.fn();
    const tree = await render(
      <RelayList
        regions={REGIONS}
        directoryStatus="loaded"
        onRelayPress={jest.fn()}
        onRetry={onRetry}
        refreshing={false}
      />,
    );
    expect(tree.root.findAllByType(ActivityIndicator)).toHaveLength(0);

    // The spinner is driven by the store's load status, passed back in as `refreshing`.
    await ReactTestRenderer.act(async () => {
      tree.update(
        <RelayList
          regions={REGIONS}
          directoryStatus="loading"
          onRelayPress={jest.fn()}
          onRetry={onRetry}
          refreshing
        />,
      );
    });
    expect(tree.root.findAllByType(ActivityIndicator)).toHaveLength(1);

    // A pull while the fetch is already in flight must not queue a second one.
    await ReactTestRenderer.act(async () => {
      tree.root
        .findByType(FlatList)
        .props.onScrollEndDrag({ nativeEvent: { contentOffset: { y: -200 } } });
    });
    expect(onRetry).not.toHaveBeenCalled();
    tree.unmount();
  });

  it('shows a non-tappable status line while loading', async () => {
    const tree = await render(
      <RelayList
        regions={[]}
        directoryStatus="loading"
        onRelayPress={jest.fn()}
        onRetry={jest.fn()}
      />,
    );
    expect(findPressables(tree)).toHaveLength(0);
    tree.root.findByProps({ children: 'locating available exit nodes…' });
    tree.unmount();
  });

  it('offers tap-to-retry when the directory failed', async () => {
    const onRetry = jest.fn();
    const tree = await render(
      <RelayList
        regions={[]}
        directoryStatus="failed"
        onRelayPress={jest.fn()}
        onRetry={onRetry}
      />,
    );
    const [retry] = findPressables(tree);
    await ReactTestRenderer.act(async () => {
      retry.props.onPress();
    });
    expect(onRetry).toHaveBeenCalledTimes(1);
    tree.unmount();
  });
});

describe('ViewModeToggle', () => {
  it('reports the newly selected mode and ignores the active segment', async () => {
    const onChange = jest.fn();
    const tree = await render(<ViewModeToggle mode="map" onChange={onChange} />);
    const [mapSegment, listSegment] = findPressables(tree);

    await ReactTestRenderer.act(async () => {
      listSegment.props.onPress();
    });
    expect(onChange).toHaveBeenCalledWith('list');

    onChange.mockClear();
    await ReactTestRenderer.act(async () => {
      mapSegment.props.onPress();
    });
    expect(onChange).not.toHaveBeenCalled();
    tree.unmount();
  });
});
