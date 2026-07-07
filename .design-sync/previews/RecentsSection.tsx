// Preview: RecentsSection — the home screen's horizontal strip of recent
// exit locations. (Empty recents render nothing, so only the filled state.)
import React from 'react';
import { RecentsSection } from 'openrung-mobile-app';

const frame: React.CSSProperties = { width: 360 };

const RECENTS = [
  { countryCode: 'JP', label: 'Tokyo, Japan', latitude: 35.68, longitude: 139.69 },
  { countryCode: 'DE', label: 'Frankfurt, Germany', latitude: 50.11, longitude: 8.68 },
  { countryCode: 'US', label: 'Ashburn, United States', latitude: 39.04, longitude: -77.49 },
  { countryCode: 'BR', label: 'São Paulo, Brazil', latitude: -23.55, longitude: -46.63 },
];

/** Four recent connections as glass pills under the uppercase label. */
export function Recents(): React.JSX.Element {
  return (
    <div style={frame}>
      <RecentsSection recents={RECENTS} onPress={() => {}} />
    </div>
  );
}
