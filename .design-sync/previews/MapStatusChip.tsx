// Preview: MapStatusChip — directory-status chip overlaid on the exit-node
// map, one cell per directoryStatus outcome (the variant axis).
import React from 'react';
import { MapStatusChip } from 'openrung-mobile-app';

// display:flex so the chip's alignSelf:'flex-start' applies and it hugs its
// text instead of stretching to the frame width.
const frame: React.CSSProperties = { width: 360, display: 'flex', alignItems: 'flex-start' };

/** Directory fetch in flight: "locating available exit nodes…". */
export function Loading(): React.JSX.Element {
  return (
    <div style={frame}>
      <MapStatusChip directoryStatus="loading" regionCount={0} onRetry={() => {}} />
    </div>
  );
}

/** Directory loaded: "%d locations available" count line. */
export function Loaded(): React.JSX.Element {
  return (
    <div style={frame}>
      <MapStatusChip directoryStatus="loaded" regionCount={12} onRetry={() => {}} />
    </div>
  );
}

/** Broker unreachable: failed-red text, tappable to retry. */
export function Failed(): React.JSX.Element {
  return (
    <div style={frame}>
      <MapStatusChip directoryStatus="failed" regionCount={0} onRetry={() => {}} />
    </div>
  );
}

/** Loaded but zero nodes: "no exit nodes available right now", tappable. */
export function EmptyLoaded(): React.JSX.Element {
  return (
    <div style={frame}>
      <MapStatusChip directoryStatus="loaded" regionCount={0} onRetry={() => {}} />
    </div>
  );
}
