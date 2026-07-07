// Preview: TabBar — bottom Home/Settings/About glass bar, one cell per
// active tab. The bar is position:absolute bottom:0 in the app, so each
// cell pins it inside a fixed-height relative frame.
import React from 'react';
import { TabBar } from 'openrung-mobile-app';

const frame: React.CSSProperties = {
  position: 'relative',
  width: 360,
  height: 84,
  overflow: 'hidden',
};

/** Home tab lit: terminal-green tint + glowing top indicator segment. */
export function HomeActive(): React.JSX.Element {
  return (
    <div style={frame}>
      <TabBar active="home" onSelect={() => {}} />
    </div>
  );
}

/** Settings tab lit, Home and About dimmed. */
export function SettingsActive(): React.JSX.Element {
  return (
    <div style={frame}>
      <TabBar active="settings" onSelect={() => {}} />
    </div>
  );
}

/** About tab lit, indicator on the right segment. */
export function AboutActive(): React.JSX.Element {
  return (
    <div style={frame}>
      <TabBar active="about" onSelect={() => {}} />
    </div>
  );
}
