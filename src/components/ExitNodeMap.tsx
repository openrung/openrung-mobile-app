/**
 * MapLibre-backed map of available volunteer exit nodes. Port of the
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
 *    halo circle (r18 @ 0.18), core circle (r6, 2px #04140A stroke), a count
 *    symbol layer (11pt "Open Sans Semibold", green with dark halo, offset
 *    [0, -1.6]) and a "City, Country" label below the dot (10pt, hidden on
 *    collision so dense clusters stay readable);
 *  - tapping a marker (28px-padded hitbox) reports the region's ISO country
 *    code so the caller can connect to a volunteer there;
 *  - `children` are rendered inside the map above the node layers, for
 *    map-space annotations (e.g. the ocean telemetry panel).
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
const NODE_LABEL_LAYER = 'openrung-exit-nodes-label';

const NODE_GREEN = '#65F58A';
const NODE_STROKE = '#04140A';

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

export interface ExitNodeMapProps {
  regions: ExitNodeRegion[];
  onRegionPress: (countryCode: string) => void;
  /** Map-space annotations (MapLibre children) rendered above the node layers. */
  children?: React.ReactNode;
}

export function ExitNodeMap({
  regions,
  onRegionPress,
  children,
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

  // One GeoJSON feature per region; code/name/count mirror the production props, label is the
  // broker-served "City, Country" (country alone when the broker only knows the country).
  const nodeCollection = useMemo(
    () => ({
      type: 'FeatureCollection' as const,
      features: regions.map(region => ({
        type: 'Feature' as const,
        geometry: {
          type: 'Point' as const,
          coordinates: [region.longitude, region.latitude],
        },
        properties: {
          code: region.countryCode,
          name: region.countryName,
          count: region.nodeCount,
          label: region.city ? `${region.city}, ${region.countryName}` : region.countryName,
        },
      })),
    }),
    [regions],
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
        initialViewState={{ center: ASIA_PACIFIC_CENTER, zoom: ASIA_PACIFIC_ZOOM }}
        minZoom={MIN_ZOOM}
        maxZoom={MAX_ZOOM}
      />
      <GeoJSONSource
        id={NODE_SOURCE}
        data={nodeCollection}
        onPress={handleNodePress}
        // Generous hit box around the dot (production queries a 28px-padded square).
        hitbox={{ top: 28, right: 28, bottom: 28, left: 28 }}
      >
        <Layer
          id={`${NODE_HALO_LAYER}-outer`}
          type="circle"
          paint={{
            'circle-radius': 27,
            'circle-color': NODE_GREEN,
            'circle-opacity': 0.07,
          }}
        />
        <Layer
          id={NODE_HALO_LAYER}
          type="circle"
          paint={{
            'circle-radius': 18,
            'circle-color': NODE_GREEN,
            'circle-opacity': 0.18,
          }}
        />
        <Layer
          id={NODE_CORE_LAYER}
          type="circle"
          paint={{
            'circle-radius': 6,
            'circle-color': NODE_GREEN,
            'circle-stroke-color': NODE_STROKE,
            'circle-stroke-width': 2,
          }}
        />
        <Layer
          id={NODE_COUNT_LAYER}
          type="symbol"
          layout={{
            'text-field': '{count}',
            'text-font': ['Open Sans Semibold'],
            'text-size': 11,
            'text-offset': [0, -1.6],
            'text-allow-overlap': true,
            'text-ignore-placement': true,
          }}
          paint={{
            'text-color': NODE_GREEN,
            'text-halo-color': NODE_STROKE,
            'text-halo-width': 1.4,
          }}
        />
        <Layer
          id={NODE_LABEL_LAYER}
          type="symbol"
          layout={{
            'text-field': '{label}',
            'text-font': ['Open Sans Semibold'],
            'text-size': 10,
            'text-offset': [0, 1.4],
            'text-anchor': 'top',
            // Unlike the count, labels yield on collision so dense clusters stay readable.
          }}
          paint={{
            'text-color': NODE_GREEN,
            'text-halo-color': NODE_STROKE,
            'text-halo-width': 1.2,
            'text-opacity': 0.9,
          }}
        />
      </GeoJSONSource>
      {children}
    </MapLibreMap>
  );
}

const styles = StyleSheet.create({
  map: {
    flex: 1,
  },
});
