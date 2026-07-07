// Preview: InfoIcon — info circle stroke icon (About tab).
import React from 'react';
import { InfoIcon } from 'openrung-mobile-app';

const row: React.CSSProperties = { display: 'flex', gap: 16, alignItems: 'center' };

/** Default size (22) in terminal green, with the dim tab-bar tint beside it. */
export function Default(): React.JSX.Element {
  return (
    <div style={row}>
      <InfoIcon color="#65F58A" />
      <InfoIcon color="#7DA989" />
    </div>
  );
}

/** Size sweep: 13, 22 (default), 32, 48 — strokes stay legible at each step. */
export function Sizes(): React.JSX.Element {
  return (
    <div style={row}>
      <InfoIcon color="#65F58A" size={13} />
      <InfoIcon color="#65F58A" size={22} />
      <InfoIcon color="#65F58A" size={32} />
      <InfoIcon color="#65F58A" size={48} />
    </div>
  );
}
