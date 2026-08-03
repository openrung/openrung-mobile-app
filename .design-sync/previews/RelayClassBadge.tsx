// Preview: RelayClassBadge — the boxed relay-class label shown right-aligned
// in relay list rows and the connect card's status row. One cell per class.
// Cells need the dark backdrop (light-on-dark text) and a flex frame so the
// badge shrink-wraps (RNW Views stretch in a plain block div) — see NOTES.md.
import React from 'react';
import { RelayClassBadge } from 'openrung-mobile-app';

const frame: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  background: '#030604',
  padding: 24,
};

/** Foundation-operated relay: terminal-green OFFICIAL box. */
export function Official(): React.JSX.Element {
  return (
    <div style={frame}>
      <RelayClassBadge nodeClass="foundation" />
    </div>
  );
}

/** Community-operated relay: orange VOLUNTEER box. */
export function Volunteer(): React.JSX.Element {
  return (
    <div style={frame}>
      <RelayClassBadge nodeClass="volunteer" />
    </div>
  );
}
