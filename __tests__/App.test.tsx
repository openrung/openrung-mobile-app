/**
 * Template render test for the OpenRung RN shell.
 *
 * Native-backed libraries are mocked:
 *  - @maplibre/maplibre-react-native: plain View stand-ins (no native map).
 *  - react-native-svg: the mock the library ships (icons, edge vignette).
 *  - @react-native-async-storage/async-storage: in-memory store.
 *  - react-native-safe-area-context: zero-inset provider/hook.
 * The OpenRungVpn native module is absent under Jest, so src/native falls
 * back to its scripted mock automatically.
 *
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';

jest.mock('@maplibre/maplibre-react-native', () => {
  const ReactActual = require('react');
  const { View } = require('react-native');
  const stub = (name: string) => {
    const Stub = ({ children, ...props }: { children?: React.ReactNode }) =>
      ReactActual.createElement(View, props, children);
    Stub.displayName = name;
    return Stub;
  };
  return {
    Map: stub('MapLibreMap'),
    Camera: stub('MapLibreCamera'),
    GeoJSONSource: stub('MapLibreGeoJSONSource'),
    Layer: stub('MapLibreLayer'),
    Marker: stub('MapLibreMarker'),
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
    Rect: stub('SvgRect'),
    Defs: stub('SvgDefs'),
    Stop: stub('SvgStop'),
    LinearGradient: stub('SvgLinearGradient'),
    RadialGradient: stub('SvgRadialGradient'),
  };
});

jest.mock('@react-native-async-storage/async-storage', () => {
  const store = new Map<string, string>();
  const instance = {
    getItem: jest.fn(async (key: string) => store.get(key) ?? null),
    setItem: jest.fn(async (key: string, value: string) => {
      store.set(key, value);
    }),
    removeItem: jest.fn(async (key: string) => {
      store.delete(key);
    }),
    clear: jest.fn(async () => {
      store.clear();
    }),
    getAllKeys: jest.fn(async () => Array.from(store.keys())),
    multiGet: jest.fn(async (keys: string[]) =>
      keys.map(key => [key, store.get(key) ?? null]),
    ),
    multiSet: jest.fn(async (pairs: [string, string][]) => {
      pairs.forEach(([key, value]) => store.set(key, value));
    }),
    multiRemove: jest.fn(async (keys: string[]) => {
      keys.forEach(key => store.delete(key));
    }),
    // async-storage v3 "next" API aliases.
    getMany: jest.fn(async (keys: string[]) =>
      Object.fromEntries(keys.map(key => [key, store.get(key) ?? null])),
    ),
    setMany: jest.fn(async (entries: Record<string, string>) => {
      Object.entries(entries).forEach(([key, value]) => store.set(key, value));
    }),
    removeMany: jest.fn(async (keys: string[]) => {
      keys.forEach(key => store.delete(key));
    }),
  };
  return {
    __esModule: true,
    default: instance,
    createAsyncStorage: () => instance,
  };
});

jest.mock('react-native-safe-area-context', () => {
  const ReactActual = require('react');
  const { View } = require('react-native');
  const insets = { top: 0, right: 0, bottom: 0, left: 0 };
  const frame = { x: 0, y: 0, width: 320, height: 640 };
  return {
    SafeAreaProvider: ({ children }: { children?: React.ReactNode }) =>
      ReactActual.createElement(View, null, children),
    SafeAreaView: ({ children }: { children?: React.ReactNode }) =>
      ReactActual.createElement(View, null, children),
    useSafeAreaInsets: () => insets,
    useSafeAreaFrame: () => frame,
    initialWindowMetrics: { insets, frame },
  };
});

// Stand-in for the native TabView: renders the active route's scene like the
// real tab controller would (Jest runs as Platform.OS === 'ios').
jest.mock('react-native-bottom-tabs', () => {
  const ReactActual = require('react');
  const { View } = require('react-native');
  const TabView = ({
    navigationState,
    renderScene,
  }: {
    navigationState: { index: number; routes: { key: string }[] };
    renderScene: (props: { route: { key: string }; jumpTo: (key: string) => void }) => React.ReactNode;
  }) =>
    ReactActual.createElement(
      View,
      null,
      renderScene({ route: navigationState.routes[navigationState.index], jumpTo: () => {} }),
    );
  return { __esModule: true, default: TabView };
});

import App from '../App';

// Keep the directory refresh (broker fetch) off the real network: reject fast so
// the store settles to 'failed' within the test instead of after teardown.
beforeAll(() => {
  (globalThis as { fetch?: unknown }).fetch = jest.fn(async () => {
    throw new Error('network disabled in tests');
  });
});

test('renders correctly', async () => {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(<App />);
  });
  // Let mount-time async work settle inside act: native getState() seed,
  // language hydration, and the (stubbed, rejecting) directory load.
  await ReactTestRenderer.act(async () => {
    await Promise.resolve();
  });
  // Unmount so nothing can schedule React updates after the test ends.
  await ReactTestRenderer.act(async () => {
    tree?.unmount();
  });
});
