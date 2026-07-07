// Preview: SettingPanel — settings/licenses row panel states, composed the
// way SettingsScreen uses them (stacked rows on the screen background).
import React from 'react';
import { SettingPanel } from 'openrung-mobile-app';

const column: React.CSSProperties = {
  width: 360,
  display: 'flex',
  flexDirection: 'column',
  gap: 10,
};

/** The settings screen's row stack: pressable, static, and custom-trailing rows. */
export function SettingsStack(): React.JSX.Element {
  return (
    <div style={column}>
      <SettingPanel
        title="Language"
        subtitle="System default"
        onPress={() => {}}
      />
      <SettingPanel
        title="Discovery broker"
        subtitle="https://broker.openrung.org/"
      />
      <SettingPanel
        title="Open-source licenses"
        subtitle="sing-box, MapLibre, and 41 more"
        onPress={() => {}}
      />
    </div>
  );
}

/** Pressable row — terminal-green chevron appears automatically. */
export function PressableRow(): React.JSX.Element {
  return (
    <div style={column}>
      <SettingPanel title="Language" subtitle="English" onPress={() => {}} />
    </div>
  );
}

/** Static row — no onPress, no chevron. */
export function StaticRow(): React.JSX.Element {
  return (
    <div style={column}>
      <SettingPanel title="Version" subtitle="0.2.3 (build 23)" />
    </div>
  );
}

/** Custom trailing element instead of the chevron. */
export function CustomTrailing(): React.JSX.Element {
  return (
    <div style={column}>
      <SettingPanel
        title="Kill switch"
        subtitle="Fails open by design"
        trailing={<span style={{ color: '#65F58A', fontSize: 12 }}>OFF</span>}
      />
    </div>
  );
}
