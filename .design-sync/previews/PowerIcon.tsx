// Preview: PowerIcon — power symbol stroke icon (connect button).
import React from 'react';
import { PowerIcon } from 'openrung-mobile-app';

const row: React.CSSProperties = { display: 'flex', gap: 16, alignItems: 'center' };

/** Default size (22) in terminal green, with the dim idle tint beside it. */
export function Default(): React.JSX.Element {
  return (
    <div style={row}>
      <PowerIcon color="#65F58A" />
      <PowerIcon color="#7DA989" />
    </div>
  );
}

/** Size sweep: 13, 22 (default), 32, 48 — strokes stay legible at each step. */
export function Sizes(): React.JSX.Element {
  return (
    <div style={row}>
      <PowerIcon color="#65F58A" size={13} />
      <PowerIcon color="#65F58A" size={22} />
      <PowerIcon color="#65F58A" size={32} />
      <PowerIcon color="#65F58A" size={48} />
    </div>
  );
}
