// Preview: OceanTelemetry — the corner-bracketed HUD that floats in the
// Pacific on the map, one cell per link lifecycle state. (The MapLibre
// Marker wrapper is shimmed to render in place on web.)
import React from 'react';
import { OceanTelemetry } from 'openrung-mobile-app';

// The HUD is translucent glass with faint glow corner brackets, composed to
// float over the dark map — give it a near-black "ocean" backdrop so the
// panel and brackets read the way they do in the app.
const frame: React.CSSProperties = {
  width: 220,
  boxSizing: 'border-box',
  padding: '28px 24px',
  background: 'radial-gradient(circle at 42% 38%, #08140d 0%, #030604 78%)',
};

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
];

/** Fresh launch: directory still loading ('…' counts), link idle. */
export function Disconnected(): React.JSX.Element {
  return (
    <div style={frame}>
      <OceanTelemetry
        regions={[]}
        directoryStatus="loading"
        status="disconnected"
        relayLabel={null}
        lastError={null}
        logLines={[]}
        connectedAtMs={null}
      />
    </div>
  );
}

/**
 * Live session: counts from the directory, volunteer name mined from the
 * "trying relay" log line, uptime clock at ~01:02:03.
 */
export function Connected(): React.JSX.Element {
  return (
    <div style={frame}>
      <OceanTelemetry
        regions={REGIONS}
        directoryStatus="loaded"
        status="connected"
        relayLabel="Tokyo, Japan"
        lastError={null}
        logLines={[
          '[14:02:10] fetching directory from broker.openrung.net',
          '[14:02:11] trying relay relay_8f2c1a9b at 203.0.113.4:443',
          '[14:02:12] tunnel interface up, mtu 1380',
        ]}
        connectedAtMs={Date.now() - 3723000}
      />
    </div>
  );
}

/** Tunnel failed: red status dot plus the native error line. */
export function Failed(): React.JSX.Element {
  return (
    <div style={frame}>
      <OceanTelemetry
        regions={REGIONS}
        directoryStatus="loaded"
        status="failed"
        relayLabel={null}
        lastError="no route to relay — network unreachable"
        logLines={['[14:05:56] relay unreachable, retrying']}
        connectedAtMs={null}
      />
    </div>
  );
}
