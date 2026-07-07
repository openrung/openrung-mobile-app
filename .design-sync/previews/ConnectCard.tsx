// Preview: ConnectCard — the home screen's hero control, one cell per
// connection lifecycle stage (the primary variant axis).
import React from 'react';
import { ConnectCard } from 'openrung-mobile-app';

const frame: React.CSSProperties = { width: 360 };

/** Idle: outlined CONNECT button, dim status dot. */
export function Disconnected(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="disconnected"
        relayLabel={null}
        isConnected={false}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Negotiating: green disc grows inside the button, live status as label. */
export function Connecting(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="connecting"
        relayLabel={null}
        isConnected={false}
        isWorking={true}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Connected: solid green DISCONNECT button, resolved exit location. */
export function Connected(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="connected"
        relayLabel="Tokyo, Japan"
        isConnected={true}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Failed: back to the outlined CONNECT button, red status dot. */
export function Failed(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="failed"
        relayLabel={null}
        isConnected={false}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}
