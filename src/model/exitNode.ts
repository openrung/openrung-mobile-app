/** One relay inside an [ExitNodeRegion]: just what the picker UI needs. */
export interface ExitNodeRelay {
  id: string; // broker relay id — what connect-to-this-relay targets
  label: string | null; // friendly name (operator-supplied or generated); null on older brokers
}

/**
 * One located exit spot on the exit-node map. Relays are grouped by the broker-served
 * exit location (country + city), so a single marker may stand for several nodes (`nodeCount`,
 * with the individual relays listed in `relays` for the list view's per-relay picker).
 * Coordinates come straight from the broker and are city-level accurate at best — the map must
 * not imply street-level precision.
 */
export interface ExitNodeRegion {
  countryCode: string; // ISO 3166-1 alpha-2, uppercase — what tap-to-connect targets
  countryName: string;
  city: string | null; // null when the broker only knows the country
  latitude: number;
  longitude: number;
  nodeCount: number;
  relays: ExitNodeRelay[]; // broker order; nodeCount === relays.length
}

// One code point per class test; `for..of` iterates code points, so astral-plane
// format characters (e.g. U+E00xx tags) are classified whole, never as surrogates.
const CONTROL_OR_FORMAT = /[\p{Cc}\p{Cf}]/u;
const SPACE_SEPARATOR = /[\p{Zs}\u2028\u2029]/u;
const MAX_RELAY_NAME_CODE_POINTS = 24;

/**
 * Renders operator-supplied relay label text safe for the UI: control/format
 * code points stripped (a bidi override could reorder or spoof surrounding
 * text), space-separator runs collapsed, clamped to 24 code points. Same
 * rules as the native `RelayDescriptor.displayName()` sanitizers (Kotlin and
 * Swift) — keep all three in sync.
 */
export function sanitizeRelayName(raw: string): string {
  let collapsed = '';
  let pendingSpace = false;
  for (const ch of raw) {
    if (CONTROL_OR_FORMAT.test(ch)) {
      continue;
    }
    if (SPACE_SEPARATOR.test(ch)) {
      pendingSpace = collapsed.length > 0;
      continue;
    }
    if (pendingSpace) {
      collapsed += ' ';
      pendingSpace = false;
    }
    collapsed += ch;
  }
  return Array.from(collapsed).slice(0, MAX_RELAY_NAME_CODE_POINTS).join('').trimEnd();
}

/**
 * Display name for a single relay wherever one is shown (list picker child
 * rows and their accessibility labels): the sanitized friendly label, or the
 * bare broker id as fallback when nothing printable remains.
 */
export function relayDisplayName(relay: ExitNodeRelay): string {
  const sanitized = relay.label != null ? sanitizeRelayName(relay.label) : '';
  return sanitized !== '' ? sanitized : relay.id.replace(/^relay_/, '').slice(0, 12);
}

/** Load state of the exit-node map directory (the list of available exit-node regions). */
export type DirectoryStatus = 'idle' | 'loading' | 'loaded' | 'failed';

/** Presentation of the exit-node directory on the home screen: map backdrop or scrollable list. */
export type HomeViewMode = 'map' | 'list';
