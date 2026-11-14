/**
 * exitNodeFeatures: the GeoJSON behind the home map's markers, including which feature the
 * map draws as the connected relay.
 */
jest.mock('@maplibre/maplibre-react-native', () => ({}));

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import { exitNodeFeatures } from '../../src/components/ExitNodeMap';
import type { ExitNodeRegion } from '../../src/model/exitNode';

const REGIONS: ExitNodeRegion[] = [
  {
    countryCode: 'JP',
    countryName: 'Japan',
    city: 'Osaka',
    latitude: 34.69,
    longitude: 135.5,
    nodeCount: 2,
    relays: [
      { id: 'relay_osaka1', label: 'proud-falcon', nodeClass: 'foundation' },
      { id: 'relay_osaka2', label: 'calm-otter', nodeClass: 'volunteer' },
    ],
  },
  {
    countryCode: 'KR',
    countryName: 'South Korea',
    city: null,
    latitude: 36.5,
    longitude: 127.9,
    nodeCount: 1,
    relays: [{ id: 'relay_kr', label: 'bold-heron', nodeClass: 'volunteer' }],
  },
];

function connectedFlags(connectedLngLat: [number, number] | null): unknown[] {
  return exitNodeFeatures(REGIONS, connectedLngLat).features.map(
    feature => feature.properties.connected,
  );
}

describe('exitNodeFeatures', () => {
  it('has one feature per region with its code, count and label', () => {
    const { features } = exitNodeFeatures(REGIONS, null);
    expect(features.map(feature => feature.properties)).toEqual([
      { code: 'JP', name: 'Japan', count: 2, label: 'Osaka, Japan', connected: false },
      { code: 'KR', name: 'South Korea', count: 1, label: 'South Korea', connected: false },
    ]);
    expect(features[0].geometry.coordinates).toEqual([135.5, 34.69]);
  });

  it("marks the region at the connected relay's coordinates", () => {
    expect(connectedFlags([127.9, 36.5])).toEqual([false, true]);
  });

  it('adds a bare point when no region sits at the connected coordinates', () => {
    const { features } = exitNodeFeatures(REGIONS, [8.68, 50.11]);
    expect(features).toHaveLength(3);
    expect(connectedFlags([8.68, 50.11])).toEqual([false, false, true]);
    // No code: a tap on it connects nowhere. No count or label text.
    expect(features[2].properties).toEqual({ count: '', label: '', connected: true });
    expect(features[2].geometry.coordinates).toEqual([8.68, 50.11]);
  });
});
