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
        relayCountryCode={null}
        connectedAtMs={null}
        errorText={null}
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
        relayCountryCode={null}
        connectedAtMs={null}
        errorText={null}
        relayClass={null}
        isConnected={false}
        isWorking={true}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Connected to a Foundation relay: name + flag, green OFFICIAL badge, uptime clock. */
export function ConnectedOfficial(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="connected"
        relayName="silly-lemur"
        relayCountryCode="JP"
        connectedAtMs={Date.now() - 754_000}
        errorText={null}
        relayClass="foundation"
        isConnected={true}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Connected to a community relay: name + flag, orange VOLUNTEER badge, uptime clock. */
export function ConnectedVolunteer(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="connected"
        relayName="brave-falcon"
        relayCountryCode="DE"
        connectedAtMs={Date.now() - 3_725_000}
        errorText={null}
        relayClass="volunteer"
        isConnected={true}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}

/** Failed: back to the outlined CONNECT button, red status dot, the reason on its own line. */
export function Failed(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConnectCard
        status="failed"
        relayName={null}
        relayCountryCode={null}
        connectedAtMs={null}
        errorText="no relay reachable"
        relayClass={null}
        isConnected={false}
        isWorking={false}
        onToggle={() => {}}
      />
    </div>
  );
}
