// Web shim for @maplibre/maplibre-react-native. Only Marker is consumed by
// the synced components (OceanTelemetry renders its HUD panel inside one);
// on web it simply renders its children in place — there is no map.
import React from 'react';
import { View } from 'react-native';

export function Marker({
  children,
}: {
  children?: React.ReactNode;
  lngLat?: [number, number];
  anchor?: string;
  pointerEvents?: string;
}): React.JSX.Element {
  return <View>{children}</View>;
}
