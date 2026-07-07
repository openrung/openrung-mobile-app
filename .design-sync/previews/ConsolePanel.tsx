// Preview: ConsolePanel — the debug console box, one cell per log state
// (ready placeholder, streaming tunnel log, trailing error, mock notice).
import React from 'react';
import { ConsolePanel } from 'openrung-mobile-app';

const frame: React.CSSProperties = {
  width: 360,
  height: 220,
  display: 'flex',
  flexDirection: 'column',
};

const grow = { flexGrow: 1 };

const TUNNEL_LOG = [
  '[14:02:09] vpn permission granted',
  '[14:02:10] fetching directory from broker.openrung.net',
  '[14:02:11] trying relay relay_8f2c1a9b at 203.0.113.4:443',
  '[14:02:12] tls handshake complete (chacha20-poly1305)',
  '[14:02:12] tunnel interface up, mtu 1380',
  '[14:02:13] exit resolved: Tokyo, Japan',
  '[14:02:13] routes installed, traffic flowing',
];

/** Empty log: shows the localized ready placeholder line. */
export function Ready(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConsolePanel logLines={[]} lastError={null} style={grow} />
    </div>
  );
}

/** A healthy connect sequence streaming in, newest last. */
export function Streaming(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConsolePanel logLines={TUNNEL_LOG} lastError={null} style={grow} />
    </div>
  );
}

/** A failed attempt: log lines plus the "! error" tail in console red. */
export function WithError(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConsolePanel
        logLines={[
          '[14:05:40] fetching directory from broker.openrung.net',
          '[14:05:41] trying relay relay_77aa19c2 at 198.51.100.23:443',
          '[14:05:56] relay unreachable, retrying',
        ]}
        lastError="handshake timed out after 15s"
        style={grow}
      />
    </div>
  );
}

/** Debug screen fallback: dim "[mock native module]" notice above the log. */
export function MockNotice(): React.JSX.Element {
  return (
    <div style={frame}>
      <ConsolePanel
        logLines={[
          '[09:12:03] mock tunnel started',
          '[09:12:04] simulated exit: Frankfurt, Germany',
        ]}
        lastError={null}
        showMockNotice
        style={grow}
      />
    </div>
  );
}
