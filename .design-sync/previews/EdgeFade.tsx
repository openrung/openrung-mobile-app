// Preview: EdgeFade — the full-bleed vignette laid over the map. Shown over
// a dim-green scanline texture standing in for map terrain so the clear
// center and darkened edges/bands are visible.
import React from 'react';
import { EdgeFade } from 'openrung-mobile-app';

/** Vignette over a map-like texture: clear center, edges dissolve to black. */
export function OverMapTexture(): React.JSX.Element {
  return (
    <div
      className="edgefade-frame"
      style={{ position: 'relative', width: 360, height: 300, overflow: 'hidden' }}
    >
      {/* react-native-svg's web <Svg> keeps the replaced-element default size
          (300x150) under absoluteFill; stretch it to the frame here. */}
      <style>{'.edgefade-frame svg { width: 100%; height: 100%; }'}</style>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background:
            'repeating-linear-gradient(0deg, rgba(74, 222, 128, 0.28) 0px, rgba(74, 222, 128, 0.28) 1px, rgba(6, 18, 10, 1) 1px, rgba(6, 18, 10, 1) 12px), repeating-linear-gradient(90deg, rgba(74, 222, 128, 0.16) 0px, rgba(74, 222, 128, 0.16) 1px, transparent 1px, transparent 12px)',
        }}
      />
      <EdgeFade />
    </div>
  );
}
