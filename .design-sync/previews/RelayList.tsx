// Preview: RelayList — the home screen's list-mode exit-node picker, with
// realistic broker directory data plus the three empty-panel states.
import React from 'react';
import { RelayList } from 'openrung-mobile-app';

const frame: React.CSSProperties = { width: 360 };

const REGIONS = [
  {
    countryCode: 'JP',
    countryName: 'Japan',
    city: 'Tokyo',
    latitude: 35.68,
    longitude: 139.69,
    nodeCount: 3,
    relays: [
      { id: 'relay_8f2c1a9b', label: 'silly-lemur' },
      { id: 'relay_02e77d41', label: 'quiet-otter' },
      { id: 'relay_c9b0f3ae', label: null },
    ],
  },
  {
    countryCode: 'DE',
    countryName: 'Germany',
    city: 'Frankfurt',
    latitude: 50.11,
    longitude: 8.68,
    nodeCount: 2,
    relays: [
      { id: 'relay_77aa19c2', label: 'brave-falcon' },
      { id: 'relay_1d4e8b06', label: 'mellow-yak' },
    ],
  },
  {
    countryCode: 'US',
    countryName: 'United States',
    city: 'Ashburn',
    latitude: 39.04,
    longitude: -77.49,
    nodeCount: 1,
    relays: [{ id: 'relay_5b39cd12', label: 'lucky-heron' }],
  },
  {
    countryCode: 'BR',
    countryName: 'Brazil',
    city: 'São Paulo',
    latitude: -23.55,
    longitude: -46.63,
    nodeCount: 1,
    relays: [{ id: 'relay_e60a2f88', label: null }],
  },
];

/** Loaded directory: flag + city rows with relay counts, sorted by country. */
export function Loaded(): React.JSX.Element {
  return (
    <div style={frame}>
      <RelayList
        regions={REGIONS}
        directoryStatus="loaded"
        onRelayPress={() => {}}
        onRetry={() => {}}
      />
    </div>
  );
}

/** First load in flight: single centered status line. */
export function Loading(): React.JSX.Element {
  return (
    <div style={frame}>
      <RelayList
        regions={[]}
        directoryStatus="loading"
        onRelayPress={() => {}}
        onRetry={() => {}}
      />
    </div>
  );
}

/** Broker unreachable: failed line in chip-failed red, tap to retry. */
export function Failed(): React.JSX.Element {
  return (
    <div style={frame}>
      <RelayList
        regions={[]}
        directoryStatus="failed"
        onRelayPress={() => {}}
        onRetry={() => {}}
      />
    </div>
  );
}

/** Loaded but empty: no exit nodes right now, tap to retry. */
export function EmptyLoaded(): React.JSX.Element {
  return (
    <div style={frame}>
      <RelayList
        regions={[]}
        directoryStatus="loaded"
        onRelayPress={() => {}}
        onRetry={() => {}}
      />
    </div>
  );
}
