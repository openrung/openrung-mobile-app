// Preview: MapIcon — folded tri-panel map stroke icon (home view toggle).
import React from 'react';
import { MapIcon } from 'openrung-mobile-app';

const row: React.CSSProperties = { display: 'flex', gap: 16, alignItems: 'center' };

/** Default size (22) in terminal green, with the dim inactive tint beside it. */
export function Default(): React.JSX.Element {
  return (
    <div style={row}>
      <MapIcon color="#65F58A" />
      <MapIcon color="#7DA989" />
    </div>
  );
}

/** Size sweep: 13, 22 (default), 32, 48 — strokes stay legible at each step. */
export function Sizes(): React.JSX.Element {
  return (
    <div style={row}>
      <MapIcon color="#65F58A" size={13} />
      <MapIcon color="#65F58A" size={22} />
      <MapIcon color="#65F58A" size={32} />
      <MapIcon color="#65F58A" size={48} />
    </div>
  );
}
