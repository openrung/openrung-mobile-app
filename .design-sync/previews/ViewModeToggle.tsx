// Preview: ViewModeToggle — MAP/LIST segmented glass pill floating over the
// home-screen map, one cell per active segment.
import React from 'react';
import { ViewModeToggle } from 'openrung-mobile-app';

// display:flex so the pill's alignSelf:'center' applies and it hugs its
// content instead of stretching to the frame width.
const frame: React.CSSProperties = { width: 360, display: 'flex', justifyContent: 'center' };

/** MAP segment active: green icon + label over the soft green fill. */
export function MapActive(): React.JSX.Element {
  return (
    <div style={frame}>
      <ViewModeToggle mode="map" onChange={() => {}} />
    </div>
  );
}

/** LIST segment active, MAP dimmed. */
export function ListActive(): React.JSX.Element {
  return (
    <div style={frame}>
      <ViewModeToggle mode="list" onChange={() => {}} />
    </div>
  );
}
