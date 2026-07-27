/**
 * Ambient telemetry readout anchored in the Pacific Ocean, directly east of
 * Shibuya at Japan's latitude. Rendered as a MapLibre Marker (not a screen
 * overlay) so it pans WITH the world: it sits just past the right screen
 * edge at the default phone camera — out of the way on launch — and slides
 * into view with the first eastward pan (tablets see it immediately).
 *
 * Read-only HUD framed by faint corner brackets (pointerEvents "none", so map
 * gestures pass straight through it):
 *  - NETWORK: live relay / location / country totals from the directory
 *    ('…' until the first load lands, '--' when the broker is unreachable);
 *  - LINK: the connection lifecycle — status dot + label, the connected
 *    relay's name (native `relayName`, the same value the connect card
 *    shows), the relay line (resolved exit location while connected, the
 *    "auto relay" target otherwise), a ticking session-uptime clock while
 *    connected, and the already-localized native `lastError` line when the
 *    tunnel failed (elsewhere that detail only surfaces in the debug
 *    console).
 */
import React, { useEffect, useMemo, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Marker } from '@maplibre/maplibre-react-native';

import { statusLabel, useStrings } from '../i18n';
import type { DirectoryStatus, ExitNodeRegion } from '../model/exitNode';
import type { ConnectionStatus } from '../native/types';
import { monoFont, palette, statusDotColor, tokens } from '../theme';

/**
 * Open Pacific DIRECTLY east of Shibuya/Tokyo (same latitude), starting just
 * past where the Shibuya marker's label ends at the default zoom. This is the
 * panel's LEFT edge, vertically centered, so every state — including the
 * taller connected/failed layouts — stays level with Japan, growing evenly
 * into open water above and below.
 *
 * Deliberately ~0.2-2° beyond the right screen edge at the default phone
 * camera (center [116, 18], zoom 2.2 puts that edge at ~143-149°E depending
 * on device width): the map is pannable, so the panel stays out of the way
 * on launch and slides in with the first eastward pan (fully in view on
 * tablets/landscape).
 */
const PACIFIC_ANCHOR: [number, number] = [146.5, 35.7];

export interface OceanTelemetryProps {
  regions: ExitNodeRegion[];
  directoryStatus: DirectoryStatus;
  status: ConnectionStatus;
  relayLabel: string | null;
  /** Friendly name of the connected relay, mirrored from native state (null while down). */
  relayName: string | null;
  lastError: string | null;
  /** Store stamp of the moment the tunnel entered 'connected'; null while down. */
  connectedAtMs: number | null;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

const MAX_UPTIME_SECONDS = 99 * 3600 + 59 * 60 + 59; // display pins at 99:59:59

/** hh:mm:ss, clamped at zero (clock skew) and at 99:59:59 so the column never widens. */
export function formatUptime(elapsedMs: number): string {
  const totalSeconds = Math.min(Math.max(0, Math.floor(elapsedMs / 1000)), MAX_UPTIME_SECONDS);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return `${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
}

function Row({ label, value }: { label: string; value: string }): React.JSX.Element {
  return (
    <View style={styles.row}>
      <Text style={styles.rowLabel} numberOfLines={1}>
        {label}
      </Text>
      <Text style={styles.rowValue} numberOfLines={1}>
        {value}
      </Text>
    </View>
  );
}

export function OceanTelemetry({
  regions,
  directoryStatus,
  status,
  relayLabel,
  relayName,
  lastError,
  connectedAtMs,
}: OceanTelemetryProps): React.JSX.Element {
  const s = useStrings();

  // Friendly name of the connected relay, straight from native state (the same value the
  // connect card's status row shows). Native clears it on every non-connected status; the
  // status guard below only defends against a briefly-stale mirror.
  const connectedRelayName = status === 'connected' ? relayName : null;

  const network = useMemo(
    () => ({
      relays: regions.reduce((sum, region) => sum + region.nodeCount, 0),
      locations: regions.length,
      countries: new Set(regions.map(region => region.countryCode)).size,
    }),
    [regions],
  );

  // Real numbers once anything is loaded; otherwise '…' while the first load
  // is in flight (or hasn't started) and '--' once the directory failed.
  const placeholder = directoryStatus === 'failed' ? '--' : '…';
  const showCounts = directoryStatus === 'loaded' || regions.length > 0;
  const count = (value: number): string => (showCounts ? String(value) : placeholder);

  // Session clock: re-sample once a second, but only while there is a live
  // session to time (the interval is torn down in every other state).
  const ticking = status === 'connected' && connectedAtMs != null;
  const [nowMs, setNowMs] = useState(() => Date.now());
  useEffect(() => {
    if (!ticking) {
      return;
    }
    setNowMs(Date.now());
    const timer = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [ticking]);

  const showError = status === 'failed' && lastError != null && lastError.length > 0;

  return (
    <Marker lngLat={PACIFIC_ANCHOR} anchor="left" pointerEvents="none">
      <View style={styles.panel} pointerEvents="none">
        <View style={[styles.corner, styles.cornerTopLeft]} />
        <View style={[styles.corner, styles.cornerTopRight]} />
        <View style={[styles.corner, styles.cornerBottomLeft]} />
        <View style={[styles.corner, styles.cornerBottomRight]} />

        <Text style={styles.header}>{s.telemetryNetworkHeader}</Text>
        <Row label={s.telemetryRelaysLabel} value={count(network.relays)} />
        <Row label={s.telemetryLocationsLabel} value={count(network.locations)} />
        <Row label={s.telemetryCountriesLabel} value={count(network.countries)} />

        <Text style={[styles.header, styles.headerSpaced]}>{s.telemetryLinkHeader}</Text>
        <View style={styles.statusRow}>
          <View style={[styles.dot, { backgroundColor: statusDotColor(status) }]} />
          <Text style={styles.statusText} numberOfLines={1}>
            {statusLabel(s, status)}
          </Text>
        </View>
        {connectedRelayName != null ? (
          <Text style={styles.relayNameText} numberOfLines={1}>
            {connectedRelayName}
          </Text>
        ) : null}
        <Text style={styles.relayText} numberOfLines={1}>
          {relayLabel ?? s.relayAuto}
        </Text>
        {status === 'connected' ? (
          <Row
            label={s.telemetryUptimeLabel}
            value={formatUptime(nowMs - (connectedAtMs ?? nowMs))}
          />
        ) : null}
        {showError ? (
          <Text style={styles.errorText} numberOfLines={3}>
            {s.errorLineFormat(lastError)}
          </Text>
        ) : null}
      </View>
    </Marker>
  );
}

const CORNER_SIZE = 9;

const styles = StyleSheet.create({
  // A whisper of glass — just enough to lift the text off faint coastlines
  // without reading as another chrome card.
  panel: {
    width: 150,
    paddingHorizontal: 14,
    paddingVertical: 12,
    backgroundColor: 'rgba(3, 6, 4, 0.55)',
  },
  corner: {
    position: 'absolute',
    width: CORNER_SIZE,
    height: CORNER_SIZE,
    borderColor: tokens.glow,
  },
  cornerTopLeft: { top: 0, left: 0, borderTopWidth: 1, borderLeftWidth: 1 },
  cornerTopRight: { top: 0, right: 0, borderTopWidth: 1, borderRightWidth: 1 },
  cornerBottomLeft: { bottom: 0, left: 0, borderBottomWidth: 1, borderLeftWidth: 1 },
  cornerBottomRight: { bottom: 0, right: 0, borderBottomWidth: 1, borderRightWidth: 1 },
  header: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 9,
    letterSpacing: 2,
    marginBottom: 3,
  },
  headerSpaced: {
    marginTop: 10,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: 8,
    marginTop: 2,
  },
  rowLabel: {
    flexShrink: 1,
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
  },
  rowValue: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 11,
  },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 2,
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: 3.5,
  },
  statusText: {
    flexShrink: 1,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 11,
    letterSpacing: 1,
  },
  relayNameText: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 10,
    marginTop: 2,
  },
  relayText: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 10,
    marginTop: 2,
  },
  errorText: {
    color: palette.consoleError,
    fontFamily: monoFont,
    fontSize: 9,
    lineHeight: 13,
    marginTop: 3,
  },
});
