// Preview: ConnectCard — the home screen's hero control, one cell per
// connection lifecycle stage (the primary variant axis), plus the two
// relay-class badges the connected status row can carry.
import React from 'react';
import { ConnectCard } from 'openrung-mobile-app';

const frame: React.CSSProperties = { width: 360 };

/** Idle: outlined CONNECT button, dim status dot. */
export function Disconnected(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="disconnected"
        relayName={null}
        relayClass={null}
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
        relayName={null}
        relayClass={null}
        isConnected={false}
        isWorking={true}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Connected to a Foundation relay: green OFFICIAL badge next to the name. */
export function ConnectedOfficial(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="connected"
        relayName="silly-lemur"
        relayClass="foundation"
        isConnected={true}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Connected to a community relay: orange VOLUNTEER badge next to the name. */
export function ConnectedVolunteer(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="connected"
        relayName="brave-falcon"
        relayClass="volunteer"
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
        relayName={null}
        relayClass={null}
        isConnected={false}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}
