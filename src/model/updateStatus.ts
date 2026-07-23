import type { DecodedUpdateManifest, UpdateNotice } from '../net/updateManifestClient';
import { compareVersions } from '../net/updateManifestClient';

/**
 * Pure derivation of the update-check UI state from a decoded manifest. The tier ladder is the
 * whole UX policy — checking is silent and constant, PROMPTING is rationed here:
 *
 * - 'none'      — up to date (or no usable manifest): zero UI.
 * - 'available' — behind the latest release: passive Settings row only. This is the default for
 *                 routine releases, and the ceiling for UNVERIFIED manifests: without a pinned-key
 *                 signature the manifest gets no banner, no notice and never a block.
 * - 'notify'    — behind AND the operator set promote="notify" (verified only): one dismissible
 *                 home-screen banner per version, then back to 'available'.
 * - 'blocked'   — below the min_supported floor (verified only): full-screen "Update required".
 *                 "Continue anyway" (session-scoped `blockOverridden`) drops it to 'available',
 *                 honouring the availability-first design — a custom-broker user on an
 *                 "unsupported" build may still work fine.
 */

export type UpdateTier = 'none' | 'available' | 'notify' | 'blocked';

export interface UpdateUiState {
  tier: UpdateTier;
  /** Latest version per the manifest (null when unknown). */
  latestVersion: string | null;
  /** Whether the manifest carried a valid pinned-key signature. */
  verified: boolean;
  /** The notice to show (already filtered: verified, undismissed, unexpired), or null. */
  notice: UpdateNotice | null;
}

export const INITIAL_UPDATE_UI: UpdateUiState = {
  tier: 'none',
  latestVersion: null,
  verified: false,
  notice: null,
};

export interface DeriveUpdateInputs {
  decoded: DecodedUpdateManifest | null;
  /** react-native Platform.OS; anything but 'android'/'ios' derives no version tier. */
  platform: string;
  currentVersion: string;
  /** Version string whose 'notify' banner the user already dismissed (persisted). */
  dismissedBannerVersion: string | null;
  /** Notice ids the user already dismissed (persisted). */
  dismissedNoticeIds: readonly string[];
  /** Session-scoped "Continue anyway" on the blocking screen. */
  blockOverridden: boolean;
  nowMs: number;
}

export function deriveUpdateUiState(inputs: DeriveUpdateInputs): UpdateUiState {
  const { decoded } = inputs;
  if (decoded === null) {
    return INITIAL_UPDATE_UI;
  }
  const { manifest, verified } = decoded;
  const info =
    inputs.platform === 'ios' ? manifest.ios : inputs.platform === 'android' ? manifest.android : null;

  const behind =
    info?.latest != null && compareVersions(inputs.currentVersion, info.latest) === -1;
  const belowFloor =
    verified &&
    info?.minSupported != null &&
    compareVersions(inputs.currentVersion, info.minSupported) === -1;

  let tier: UpdateTier;
  if (belowFloor) {
    // "Continue anyway" lands on the passive row, never the banner — the user just declined the
    // strongest prompt this session; a second, weaker prompt would only nag.
    tier = inputs.blockOverridden ? 'available' : 'blocked';
  } else if (behind) {
    tier =
      verified &&
      manifest.promote === 'notify' &&
      info?.latest != null &&
      inputs.dismissedBannerVersion !== info.latest
        ? 'notify'
        : 'available';
  } else {
    tier = 'none';
  }

  const notice =
    verified &&
    manifest.notice !== null &&
    !inputs.dismissedNoticeIds.includes(manifest.notice.id) &&
    (manifest.notice.expiresMs === null || manifest.notice.expiresMs > inputs.nowMs)
      ? manifest.notice
      : null;

  return { tier, latestVersion: info?.latest ?? null, verified, notice };
}

/**
 * Picks the best translation from a server-sent {locale: text} map for a resolved app language
 * tag: exact tag, then primary subtag, then English. Decoding guarantees 'en' exists.
 */
export function pickLocalizedText(map: Record<string, string>, resolvedTag: string): string {
  if (typeof map[resolvedTag] === 'string') {
    return map[resolvedTag];
  }
  const primary = resolvedTag.split('-')[0];
  if (typeof map[primary] === 'string') {
    return map[primary];
  }
  return map.en;
}
