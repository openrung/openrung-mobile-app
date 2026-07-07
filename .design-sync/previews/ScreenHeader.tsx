// Preview: ScreenHeader — shared sub-screen header (back arrow + bold mono
// title), shown with the two real sub-screen titles.
import React from 'react';
import { ScreenHeader } from 'openrung-mobile-app';

const frame: React.CSSProperties = { width: 360 };

/** Settings screen header: ← arrow, 8dp spacer, 22sp bold title. */
export function Settings(): React.JSX.Element {
  return (
    <div style={frame}>
      <ScreenHeader title="Settings" onBack={() => {}} />
    </div>
  );
}

/** About screen header with a longer title. */
export function About(): React.JSX.Element {
  return (
    <div style={frame}>
      <ScreenHeader title="About OpenRung" onBack={() => {}} />
    </div>
  );
}
