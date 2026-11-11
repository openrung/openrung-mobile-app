/**
 * MapLibre-backed map of available relay exit nodes. Port of the
 * production Android ExitNodeMap.kt onto @maplibre/maplibre-react-native v11:
 *
 *  - custom "openrung-neon" style JSON around the MapLibre demo vector tiles
 *    (black ocean, faint green land fill, neon-green outlines) — deliberately
 *    omitting the demo style's per-country colours, graticule and labels;
 *  - opens on the Asia-Pacific overview (center [116, 18], zoom 2.2); pan and
 *    pinch-zoom (1.2..4.8) are enabled so the full-screen map feels alive,
 *    rotate/tilt stay disabled to keep the HUD framing;
 *  - one GeoJSON feature per region — a broker-served exit location, so
 *    markers are city-level where the broker knows the city — rendered as
 *    halo circle (r18 @ 0.18), core circle (r6, 2px #04140A stroke), a ring
 *    (connected relay only), a count
 *    symbol layer (11pt "Open Sans Semibold", green with dark halo, offset
 *    [0, -1.6]) and a "City, Country" label below the dot (10pt, hidden on
 *    collision so dense clusters stay readable);
 *  - tapping a marker (28px-padded hitbox) reports the region's ISO country
 *    code so the caller can connect to a relay there;
 *  - while connected, the session's relay is marked with a brighter core, a
 *    ring and a wider glow — the same layers, switched by the feature's
 *    `connected` property, so the count and city label stay on top — and the
 *    camera eases over to it (zoom unchanged).
 */
import React, { useCallback, useMemo } from 'react';
import { StyleSheet, type NativeSyntheticEvent } from 'react-native';
import {
  Camera,
  GeoJSONSource,
  Layer,
  Map as MapLibreMap,
  type PressEventWithFeatures,
  type StyleSpecification,
} from '@maplibre/maplibre-react-native';

import { AppConfig } from '../config';
import { useStrings } from '../i18n';
import type { ExitNodeRegion } from '../model/exitNode';

const NODE_SOURCE = 'openrung-exit-nodes';
const NODE_HALO_LAYER = 'openrung-exit-nodes-halo';
const NODE_CORE_LAYER = 'openrung-exit-nodes-core';
const NODE_COUNT_LAYER = 'openrung-exit-nodes-count';
const NODE_RING_LAYER = 'openrung-exit-nodes-ring';
const NODE_LABEL_LAYER = 'openrung-exit-nodes-label';

const NODE_GREEN = '#65F58A';
const NODE_STROKE = '#04140A';
const CONNECTED_CORE = '#D8FFE0';

// Dark neon basemap palette: black ocean, faintly-shaded green land, neon-green borders.
const OCEAN_COLOR = '#030604'; // app backdrop, so the map blends edge-to-edge
const LAND_COLOR = '#65F58A'; // brand green, drawn translucent (see opacity)
const LAND_FILL_OPACITY = 0.12;
const LAND_OUTLINE_COLOR = '#65F58A'; // neon-green coastlines / country borders

// Asia-Pacific overview the map opens to (centred over the East/South-East Asian seas).
const ASIA_PACIFIC_CENTER: [number, number] = [116, 18];
const ASIA_PACIFIC_ZOOM = 2.2;
const MIN_ZOOM = 1.2;
const MAX_ZOOM = 4.8;

// Module-level constants for every static Layer/Camera/hitbox prop: fresh object literals per
// render would make RN re-diff (and potentially re-push) all map-layer props on each pass.
const INITIAL_VIEW_STATE = { center: ASIA_PACIFIC_CENTER, zoom: ASIA_PACIFIC_ZOOM };
const NODE_HITBOX = { top: 28, right: 28, bottom: 28, left: 28 };
/**
 * A paint value that differs for the feature standing for the connected relay (its `connected`
 * property, see exitNodeFeatures). The tuple type is what the style spec's `case` expects.
 */
function whenConnected<T extends number | string>(
  connected: T,
  otherwise: T,
): ['case', ['boolean', ['get', string], boolean], T, T] {
  return ['case', ['boolean', ['get', 'connected'], false], connected, otherwise];
}
const HALO_OUTER_PAINT = {
  'circle-radius': whenConnected(30, 27),
  'circle-color': NODE_GREEN,
  'circle-opacity': whenConnected(0.22, 0.07),
};
const HALO_PAINT = {
  'circle-radius': 18,
  'circle-color': NODE_GREEN,
  'circle-opacity': 0.18,
};
const CORE_PAINT = {
  'circle-radius': 6,
  'circle-color': whenConnected(CONNECTED_CORE, NODE_GREEN),
  'circle-stroke-color': NODE_STROKE,
  'circle-stroke-width': 2,
};
// Invisible except around the connected relay.
const RING_PAINT = {
  'circle-radius': 10.5,
  'circle-opacity': 0,
  'circle-stroke-color': NODE_GREEN,
  'circle-stroke-width': 1.5,
  'circle-stroke-opacity': whenConnected(1, 0),
};
const COUNT_LAYOUT = {
  'text-field': '{count}',
  'text-font': ['Open Sans Semibold'],
  'text-size': 11,
  'text-offset': [0, -1.6] as [number, number],
  'text-allow-overlap': true,
  'text-ignore-placement': true,
};
const COUNT_PAINT = {
  'text-color': NODE_GREEN,
  'text-halo-color': NODE_STROKE,
  'text-halo-width': 1.4,
};
const LABEL_LAYOUT = {
  'text-field': '{label}',
  'text-font': ['Open Sans Semibold'],
  'text-size': 10,
  'text-offset': [0, 1.4] as [number, number],
  'text-anchor': 'top' as const,
  // Unlike the count, labels yield on collision so dense clusters stay readable.
};
const CONNECTED_CAMERA_MS = 1000;
const NO_CAMERA_STOP = {};
const LABEL_PAINT = {
  'text-color': NODE_GREEN,
  'text-halo-color': NODE_STROKE,
  'text-halo-width': 1.2,
  'text-opacity': 0.9,
};

/**
 * One GeoJSON feature per region; code/name/count mirror the production props, label is the
 * broker-served "City, Country" (country alone when the broker only knows the country).
 * `connected` marks the region at the connected relay's coordinates. When no region sits
 * there (the directory does not list the relay), a bare extra point stands for it: no code,
 * so a tap on it connects nowhere, and no count or label text.
 */
export function exitNodeFeatures(
  regions: ExitNodeRegion[],
  connectedLngLat: readonly [number, number] | null,
) {
  const [longitude, latitude] = connectedLngLat ?? [];
  const point = (coordinates: [number, number], properties: Record<string, unknown>) => ({
    type: 'Feature' as const,
    geometry: { type: 'Point' as const, coordinates },
    properties,
  });
  const features = regions.map(region =>
    point([region.longitude, region.latitude], {
      code: region.countryCode,
      name: region.countryName,
      count: region.nodeCount,
      label: region.city ? `${region.city}, ${region.countryName}` : region.countryName,
      connected: region.longitude === longitude && region.latitude === latitude,
    }),
  );
  if (
    longitude != null &&
    latitude != null &&
    !features.some(feature => feature.properties.connected === true)
  ) {
    features.push(point([longitude, latitude], { count: '', label: '', connected: true }));
  }
  return { type: 'FeatureCollection' as const, features };
}

export interface ExitNodeMapProps {
  regions: ExitNodeRegion[];
  onRegionPress: (countryCode: string) => void;
  /** [longitude, latitude] of the connected relay; null while not connected or unlocated. */
  connectedLngLat?: [number, number] | null;
}

export function ExitNodeMap({
  regions,
  onRegionPress,
  connectedLngLat = null,
}: ExitNodeMapProps): React.JSX.Element {
  const s = useStrings();

  const mapStyle = useMemo<StyleSpecification>(
    () => ({
      version: 8,
      name: 'openrung-neon',
      glyphs: AppConfig.MAP_GLYPHS_URL,
      sources: {
        maplibre: { type: 'vector', url: AppConfig.MAP_TILES_URL },
      },
      layers: [
        {
          id: 'ocean',
          type: 'background',
          paint: { 'background-color': OCEAN_COLOR },
        },
        {
          id: 'land',
          type: 'fill',
          source: 'maplibre',
          'source-layer': 'countries',
          paint: { 'fill-color': LAND_COLOR, 'fill-opacity': LAND_FILL_OPACITY },
        },
        {
          id: 'land-outline',
          type: 'line',
          source: 'maplibre',
          'source-layer': 'countries',
          paint: { 'line-color': LAND_OUTLINE_COLOR, 'line-width': 1.0, 'line-opacity': 0.85 },
        },
      ],
    }),
    [],
  );

  // Keyed on the two numbers, so a caller passing a fresh array per render neither rebuilds
  // the markers nor re-sends the camera stop (which would pull a panned map back).
  const connectedLongitude = connectedLngLat?.[0];
  const connectedLatitude = connectedLngLat?.[1];
  const connectedCenter = useMemo<[number, number] | null>(
    () =>
      connectedLongitude == null || connectedLatitude == null
        ? null
        : [connectedLongitude, connectedLatitude],
    [connectedLongitude, connectedLatitude],
  );
  const nodeCollection = useMemo(
    () => exitNodeFeatures(regions, connectedCenter),
    [regions, connectedCenter],
  );
  // A camera stop without a zoom keeps the user's zoom level and only recenters.
  const cameraStop = useMemo(
    () =>
      connectedCenter == null
        ? NO_CAMERA_STOP
        : { center: connectedCenter, duration: CONNECTED_CAMERA_MS, easing: 'ease' as const },
    [connectedCenter],
  );

  const handleNodePress = useCallback(
    (event: NativeSyntheticEvent<PressEventWithFeatures>) => {
      for (const feature of event.nativeEvent.features ?? []) {
        const code = feature?.properties?.code;
        if (typeof code === 'string') {
          onRegionPress(code);
          return;
        }
      }
    },
    [onRegionPress],
  );

  return (
    <MapLibreMap
      style={styles.map}
      mapStyle={mapStyle}
      // Pan + pinch-zoom enabled for the full-screen backdrop; rotate/tilt stay off.
      touchZoom
      doubleTapZoom
      doubleTapHoldZoom={false}
      touchRotate={false}
      touchPitch={false}
      compass={false}
      logo={false}
      attribution={false}
      // Texture mode so the map composites cleanly under the RN overlays (vignette, cards).
      androidView="texture"
      accessibilityLabel={s.mapContentDescription}
    >
      <Camera
        initialViewState={INITIAL_VIEW_STATE}
        minZoom={MIN_ZOOM}
        maxZoom={MAX_ZOOM}
        {...cameraStop}
      />
      <GeoJSONSource
        id={NODE_SOURCE}
        data={nodeCollection}
        onPress={handleNodePress}
        // Generous hit box around the dot (production queries a 28px-padded square).
        hitbox={NODE_HITBOX}
      >
        <Layer id={`${NODE_HALO_LAYER}-outer`} type="circle" paint={HALO_OUTER_PAINT} />
        <Layer id={NODE_HALO_LAYER} type="circle" paint={HALO_PAINT} />
        <Layer id={NODE_CORE_LAYER} type="circle" paint={CORE_PAINT} />
        <Layer id={NODE_RING_LAYER} type="circle" paint={RING_PAINT} />
        <Layer id={NODE_COUNT_LAYER} type="symbol" layout={COUNT_LAYOUT} paint={COUNT_PAINT} />
        <Layer id={NODE_LABEL_LAYER} type="symbol" layout={LABEL_LAYOUT} paint={LABEL_PAINT} />
      </GeoJSONSource>
    </MapLibreMap>
  );
}

const styles = StyleSheet.create({
  map: {
    flex: 1,
  },
});
