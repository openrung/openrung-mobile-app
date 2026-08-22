// Preview: RecentsSection — the home screen's horizontal strip of recent
// exit locations. (Empty recents render nothing; entries without a pinned
// relayId/relayName, or whose relay the broker no longer lists, are hidden.)
import React from 'react';
import { RecentsSection } from 'openrung-mobile-app';

const frame: React.CSSProperties = { width: 360 };

const RECENTS = [
  {
    countryCode: 'JP',
    relayId: 'relay_8f2c1a9b',
    label: 'Tokyo, Japan',
    relayName: 'silly-lemur',
    latitude: 35.68,
    longitude: 139.69,
  },
  {
    countryCode: 'DE',
    relayId: 'relay_77aa19c2',
    label: 'Frankfurt, Germany',
    relayName: 'brave-falcon',
    latitude: 50.11,
    longitude: 8.68,
  },
  {
    countryCode: 'US',
    relayId: 'relay_5b39cd12',
    label: 'Ashburn, United States',
    relayName: 'lucky-heron',
    latitude: 39.04,
    longitude: -77.49,
  },
  {
    countryCode: 'BR',
    relayId: 'relay_02e77d41',
    label: 'São Paulo, Brazil',
    relayName: 'quiet-otter',
    latitude: -23.55,
    longitude: -46.63,
  },
];

// Every pinned relay is still listed by the broker, so all four pills show.
const LIVE_RELAY_IDS: ReadonlySet<string> = new Set(RECENTS.map(node => node.relayId));

/** Four recent connections as glass pills under the uppercase label. */
export function Recents(): React.JSX.Element {
  return (
    <div style={frame}>
      <RecentsSection recents={RECENTS} liveRelayIds={LIVE_RELAY_IDS} onPress={() => {}} />
    </div>
  );
}
