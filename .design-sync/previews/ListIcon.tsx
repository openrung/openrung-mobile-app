// Preview: ListIcon — bulleted rows stroke icon (home view toggle).
import React from 'react';
import { ListIcon } from 'openrung-mobile-app';

const row: React.CSSProperties = { display: 'flex', gap: 16, alignItems: 'center' };

/** Default size (22) in terminal green, with the dim inactive tint beside it. */
export function Default(): React.JSX.Element {
  return (
    <div style={row}>
      <ListIcon color="#65F58A" />
      <ListIcon color="#7DA989" />
    </div>
  );
}

/** Size sweep: 13, 22 (default), 32, 48 — strokes stay legible at each step. */
export function Sizes(): React.JSX.Element {
  return (
    <div style={row}>
      <ListIcon color="#65F58A" size={13} />
      <ListIcon color="#65F58A" size={22} />
      <ListIcon color="#65F58A" size={32} />
      <ListIcon color="#65F58A" size={48} />
    </div>
  );
}
