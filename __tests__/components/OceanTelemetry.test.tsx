/**
 * Ocean telemetry panel (the map-space HUD anchored over the Pacific):
 *  - NETWORK totals derive from the directory regions (relay sum, location
 *    count, distinct countries), with '…' before the first load and '--'
 *    after a failed one;
 *  - LINK narrates the connection: status label always; relay location and a
 *    ticking hh:mm:ss uptime clock only while connected; the native lastError
 *    line only when failed.
 */
import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Text } from 'react-native';

// Pulled in via i18n -> store; an in-memory stand-in keeps Jest off the native module.
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

// The panel renders inside a MapLibre Marker; a plain View stand-in is enough.
jest.mock('@maplibre/maplibre-react-native', () => {
  const ReactActual = require('react');
  const { View } = require('react-native');
  const Marker = ({ children, ...props }: { children?: React.ReactNode }) =>
    ReactActual.createElement(View, props, children);
  Marker.displayName = 'MapLibreMarker';
  return { Marker };
});

import {
  OceanTelemetry,
  formatUptime,
  lastDialledRelay,
} from '../../src/components/OceanTelemetry';
import type { OceanTelemetryProps } from '../../src/components/OceanTelemetry';
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

const BASE_PROPS: OceanTelemetryProps = {
  regions: REGIONS,
  directoryStatus: 'loaded',
  status: 'disconnected',
  relayLabel: null,
  lastError: null,
  logLines: [],
  connectedAtMs: null,
};

async function render(element: React.ReactElement): Promise<ReactTestRenderer.ReactTestRenderer> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(element);
  });
  return tree!;
}

function texts(tree: ReactTestRenderer.ReactTestRenderer): string[] {
  return tree.root
    .findAllByType(Text)
    .map(node => node.props.children)
    .filter((child): child is string => typeof child === 'string');
}

describe('formatUptime', () => {
  it('renders zero-padded hh:mm:ss', () => {
    expect(formatUptime(0)).toBe('00:00:00');
    expect(formatUptime(65_000)).toBe('00:01:05');
    expect(formatUptime(3_661_000)).toBe('01:01:01');
  });

  it('clamps negative elapsed (clock skew) to zero', () => {
    expect(formatUptime(-5_000)).toBe('00:00:00');
  });

  it('pins at 99:59:59 without widening the column', () => {
    expect(formatUptime(99 * 3_600_000)).toBe('99:00:00');
    expect(formatUptime(500 * 3_600_000)).toBe('99:59:59');
  });
});

describe('lastDialledRelay', () => {
  it('recovers the most recently dialled relay by id token, across localized log text', () => {
    const logLines = [
      '[09:00:01] trying relay relay_de1 at 198.51.100.7:443',
      '[09:00:03] relay relay_de1 failed: timeout',
      '[09:00:04] 正在嘗試中繼 relay_jp1（203.0.113.10:443）',
      '[09:00:06] Connected',
    ];
    expect(lastDialledRelay(logLines, REGIONS)?.label).toBe('proud-falcon');
  });

  it('matches whole tokens only, never an id inside a longer token', () => {
    const logLines = ['[09:00:00] trying relay relay_jp2x at 203.0.113.11:443'];
    expect(lastDialledRelay(logLines, REGIONS)).toBeNull();
  });

  it('returns null when the log mentions no known relay id', () => {
    expect(lastDialledRelay(['[09:00:00] fetching relays'], REGIONS)).toBeNull();
    expect(lastDialledRelay([], REGIONS)).toBeNull();
    expect(lastDialledRelay(['[09:00:00] trying relay relay_jp1 at h:443'], [])).toBeNull();
  });
});

describe('OceanTelemetry', () => {
  it('shows relay, location, and distinct-country totals from the directory', async () => {
    const tree = await render(<OceanTelemetry {...BASE_PROPS} />);
    const rendered = texts(tree);
    // 2 + 1 + 3 relays across 3 locations in 2 countries; the relay line
    // shows the auto-relay target while not connected.
    expect(rendered).toEqual([
      'NETWORK',
      'relays',
      '6',
      'locations',
      '3',
      'countries',
      '2',
      'LINK',
      'Disconnected',
      'auto relay',
    ]);
    tree.unmount();
  });

  it("shows '…' placeholders until the first directory load lands", async () => {
    const tree = await render(
      <OceanTelemetry {...BASE_PROPS} regions={[]} directoryStatus="loading" />,
    );
    expect(texts(tree).filter(value => value === '…')).toHaveLength(3);
    tree.unmount();
  });

  it("shows '--' placeholders when the directory failed", async () => {
    const tree = await render(
      <OceanTelemetry {...BASE_PROPS} regions={[]} directoryStatus="failed" />,
    );
    expect(texts(tree).filter(value => value === '--')).toHaveLength(3);
    tree.unmount();
  });

  it('shows real zeros for a loaded-but-empty directory', async () => {
    const tree = await render(
      <OceanTelemetry {...BASE_PROPS} regions={[]} directoryStatus="loaded" />,
    );
    expect(texts(tree).filter(value => value === '0')).toHaveLength(3);
    tree.unmount();
  });

  it('while connected, shows the relay location and a ticking uptime clock', async () => {
    jest.useFakeTimers();
    try {
      const connectedAtMs = Date.now() - 65_000; // connected 1m05s ago
      const tree = await render(
        <OceanTelemetry
          {...BASE_PROPS}
          status="connected"
          relayLabel="Tokyo, Japan"
          connectedAtMs={connectedAtMs}
        />,
      );
      let rendered = texts(tree);
      expect(rendered).toContain('Connected');
      expect(rendered).toContain('Tokyo, Japan');
      expect(rendered).toContain('uptime');
      expect(rendered).toContain('00:01:05');

      await ReactTestRenderer.act(async () => {
        jest.advanceTimersByTime(2_000);
      });
      rendered = texts(tree);
      expect(rendered).toContain('00:01:07');
      tree.unmount();
    } finally {
      jest.useRealTimers();
    }
  });

  it('shows the friendly name of the relay the tunnel dialled, only while connected', async () => {
    jest.useFakeTimers();
    try {
      const logLines = ['[09:00:00] trying relay relay_jp1 at 203.0.113.10:443'];
      const connected = await render(
        <OceanTelemetry
          {...BASE_PROPS}
          status="connected"
          relayLabel="Tokyo, Japan"
          logLines={logLines}
          connectedAtMs={Date.now()}
        />,
      );
      expect(texts(connected)).toContain('proud-falcon');
      connected.unmount();

      // The same log lines show no name while disconnected (stale sessions).
      const disconnected = await render(<OceanTelemetry {...BASE_PROPS} logLines={logLines} />);
      expect(texts(disconnected)).not.toContain('proud-falcon');
      disconnected.unmount();
    } finally {
      jest.useRealTimers();
    }
  });

  it('falls back to the bare relay id when the relay has no friendly name', async () => {
    jest.useFakeTimers();
    try {
      const tree = await render(
        <OceanTelemetry
          {...BASE_PROPS}
          status="connected"
          relayLabel="Tokyo, Japan"
          logLines={['[09:00:00] trying relay relay_jp2 at 203.0.113.11:443']}
          connectedAtMs={Date.now()}
        />,
      );
      // Same fallback as the list picker's child rows ("relay_" prefix stripped).
      expect(texts(tree)).toContain('jp2');
      tree.unmount();
    } finally {
      jest.useRealTimers();
    }
  });

  it('falls back to the auto-relay label when connected without a resolved location', async () => {
    jest.useFakeTimers();
    try {
      const tree = await render(
        <OceanTelemetry {...BASE_PROPS} status="connected" connectedAtMs={Date.now()} />,
      );
      expect(texts(tree)).toContain('auto relay');
      tree.unmount();
    } finally {
      jest.useRealTimers();
    }
  });

  it('surfaces the native lastError line only in the failed state', async () => {
    const failed = await render(
      <OceanTelemetry
        {...BASE_PROPS}
        status="failed"
        lastError="broker unreachable: all candidates failed"
      />,
    );
    expect(texts(failed)).toContain('! broker unreachable: all candidates failed');
    failed.unmount();

    // The same stale error is NOT shown once the user is simply disconnected.
    const disconnected = await render(
      <OceanTelemetry
        {...BASE_PROPS}
        status="disconnected"
        lastError="broker unreachable: all candidates failed"
      />,
    );
    expect(texts(disconnected).some(value => value.startsWith('!'))).toBe(false);
    disconnected.unmount();
  });

  it('shows the auto-relay target but no uptime row while disconnected', async () => {
    const tree = await render(<OceanTelemetry {...BASE_PROPS} />);
    const rendered = texts(tree);
    expect(rendered).toContain('auto relay');
    expect(rendered).not.toContain('uptime');
    tree.unmount();
  });
});
