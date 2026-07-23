import AsyncStorage from '@react-native-async-storage/async-storage';
import { AppState, Platform, type NativeEventSubscription } from 'react-native';

import { APP_VERSION, AppConfig } from '../config';
import { deriveUpdateUiState } from '../model/updateStatus';
import {
  decodeUpdateEnvelope,
  fetchUpdateManifest,
  type DecodedUpdateManifest,
  type UpdatePlatformInfo,
} from '../net/updateManifestClient';
import { applyUpdateUiState } from './store';

/**
 * Update-check orchestration: hydrates the persisted manifest, refreshes it on cold start and on
 * every return to foreground (throttled), and mirrors the derived UI tier into the store. The
 * whole service is fail-open by construction — every network or storage failure leaves the app
 * exactly as it was, and the check never gates startup or connect.
 *
 * The raw envelope is persisted VERBATIM and re-verified on every hydrate: AsyncStorage is not
 * trusted storage, so "verified" is never a persisted bit — it is recomputed from the signature
 * each launch against the currently pinned keys.
 */

export const UPDATE_MANIFEST_STORAGE_KEY = 'openrung.updateManifest';
export const UPDATE_CHECKED_AT_STORAGE_KEY = 'openrung.updateManifestCheckedAt';
export const UPDATE_DISMISSED_BANNER_STORAGE_KEY = 'openrung.updateDismissedBanner';
export const UPDATE_DISMISSED_NOTICES_STORAGE_KEY = 'openrung.updateDismissedNotices';

/** Dismissed-notice ids kept, newest last — bounds storage while far exceeding realistic use. */
const MAX_DISMISSED_NOTICE_IDS = 20;

let decoded: DecodedUpdateManifest | null = null;
let lastSuccessAtMs = 0; // persisted (UPDATE_CHECKED_AT_STORAGE_KEY)
let lastAttemptAtMs = 0; // in-memory: failed-attempt backoff resets each app session
let dismissedBannerVersion: string | null = null;
let dismissedNoticeIds: string[] = [];
let blockOverridden = false; // session-scoped "Continue anyway"
let fetchInFlight = false;
let started = false;
let appStateSubscription: NativeEventSubscription | null = null;

function platformInfo(candidate: DecodedUpdateManifest | null): UpdatePlatformInfo | null {
  if (candidate === null) {
    return null;
  }
  return Platform.OS === 'ios'
    ? candidate.manifest.ios
    : Platform.OS === 'android'
      ? candidate.manifest.android
      : null;
}

function recompute(): void {
  applyUpdateUiState(
    deriveUpdateUiState({
      decoded,
      platform: Platform.OS,
      currentVersion: APP_VERSION,
      dismissedBannerVersion,
      dismissedNoticeIds,
      blockOverridden,
      nowMs: Date.now(),
    }),
  );
}

async function hydrate(): Promise<void> {
  try {
    const [raw, checkedAt, banner, notices] = await Promise.all([
      AsyncStorage.getItem(UPDATE_MANIFEST_STORAGE_KEY),
      AsyncStorage.getItem(UPDATE_CHECKED_AT_STORAGE_KEY),
      AsyncStorage.getItem(UPDATE_DISMISSED_BANNER_STORAGE_KEY),
      AsyncStorage.getItem(UPDATE_DISMISSED_NOTICES_STORAGE_KEY),
    ]);
    // Never clobber a manifest a concurrently-completed refresh already installed: the fetched
    // copy went through the shouldReplaceCache ladder, the persisted one would bypass it.
    if (raw !== null && decoded === null) {
      try {
        decoded = decodeUpdateEnvelope(raw);
      } catch {
        // Cache no longer decodes/verifies (corruption, key rotation): drop it.
        AsyncStorage.removeItem(UPDATE_MANIFEST_STORAGE_KEY).catch(() => {});
      }
    }
    const checkedAtMs = checkedAt !== null ? Number(checkedAt) : Number.NaN;
    if (Number.isFinite(checkedAtMs) && checkedAtMs > 0) {
      // Clamp to now: a timestamp persisted under a fast-forwarded clock must not freeze the 6h
      // throttle (and thereby all floor/notice delivery) until wall-clock catches up. Max with
      // the in-memory value so hydration never rolls back a success recorded this session.
      lastSuccessAtMs = Math.max(lastSuccessAtMs, Math.min(checkedAtMs, Date.now()));
    }
    if (banner !== null && banner.length > 0) {
      dismissedBannerVersion = banner;
    }
    if (notices !== null) {
      try {
        const parsed: unknown = JSON.parse(notices);
        if (Array.isArray(parsed) && parsed.every(id => typeof id === 'string')) {
          dismissedNoticeIds = parsed;
        }
      } catch {
        // Corrupt list: keep the empty default (worst case a dismissed notice reappears once).
      }
    }
  } catch {
    // Storage unavailable: run from in-memory defaults.
  }
}

/**
 * Replacement trust ladder — the fetched manifest replaces the cached one only when that never
 * DOWNGRADES trust or rolls history back:
 * - verified fetch over verified cache: STRICTLY newer generated_at only. The publisher stamps
 *   generated_at with the newest of ALL its inputs (latest-main commit time, latest release
 *   published_at), so an equal stamp means an identical manifest — replacing would be a no-op —
 *   and on any equal-but-different edge, first-writer-wins avoids cache flapping between fronts.
 *   A replayed OLDER signed manifest can never roll back a raised floor.
 * - unsigned fetch: accepted only while the cache is absent or itself unsigned. Once any verified
 *   manifest has been seen, an unsigned body (e.g. a front stripping the sig) can never displace
 *   it. Unsigned-over-unsigned is last-write-wins: an unsigned generated_at proves nothing, and
 *   its blast radius is capped at the passive tier anyway.
 */
function shouldReplaceCache(fetched: DecodedUpdateManifest): boolean {
  if (decoded === null) {
    return true;
  }
  if (fetched.verified) {
    return !decoded.verified || fetched.manifest.generatedAtMs > decoded.manifest.generatedAtMs;
  }
  return !decoded.verified;
}

/**
 * Refreshes the manifest if due (6h after a success, 15min after a failed attempt; `force` skips
 * both). Never throws, never blocks callers on the network.
 */
export async function refreshUpdateManifest(force: boolean = false): Promise<void> {
  const now = Date.now();
  if (fetchInFlight) {
    return;
  }
  if (!force) {
    // Negative deltas (a timestamp from a clock that has since been set back) count as due:
    // one extra fetch self-heals the bogus stamp instead of freezing the cadence.
    const sinceSuccess = now - lastSuccessAtMs;
    if (lastSuccessAtMs > 0 && sinceSuccess >= 0 && sinceSuccess < AppConfig.UPDATE_CHECK_INTERVAL_MS) {
      return;
    }
    const sinceAttempt = now - lastAttemptAtMs;
    if (lastAttemptAtMs > 0 && sinceAttempt >= 0 && sinceAttempt < AppConfig.UPDATE_CHECK_RETRY_MS) {
      return;
    }
  }
  fetchInFlight = true;
  lastAttemptAtMs = now;
  try {
    const fetched = await fetchUpdateManifest(AppConfig.UPDATE_MANIFEST_URLS, {
      // The cached verified generated_at is the freshness floor: the walk stops at the first
      // front at least this fresh and keeps going past staler (replayed) signed copies.
      atLeastGeneratedAtMs: decoded !== null && decoded.verified ? decoded.manifest.generatedAtMs : null,
    });
    if (fetched === null) {
      return; // all candidates failed — fail open, retry after UPDATE_CHECK_RETRY_MS
    }
    const cached = decoded;
    const trustDowngrade = cached !== null && cached.verified && !fetched.decoded.verified;
    const staleReplay =
      cached !== null &&
      cached.verified &&
      fetched.decoded.verified &&
      fetched.decoded.manifest.generatedAtMs < cached.manifest.generatedAtMs;
    if (trustDowngrade || staleReplay) {
      // Best copy anywhere was sig-stripped, or every verified copy was OLDER than our cache
      // (a replayed signed manifest): treat it as a FAILED check (15-min retry cadence), not a
      // success — otherwise a bad front could freeze floor/notice delivery behind the 6h
      // success throttle.
      return;
    }
    lastSuccessAtMs = Date.now();
    AsyncStorage.setItem(UPDATE_CHECKED_AT_STORAGE_KEY, String(lastSuccessAtMs)).catch(() => {});
    if (shouldReplaceCache(fetched.decoded)) {
      decoded = fetched.decoded;
      AsyncStorage.setItem(UPDATE_MANIFEST_STORAGE_KEY, fetched.raw).catch(() => {});
      recompute();
    }
  } catch {
    // fetchUpdateManifest never throws by contract; this is belt-and-braces fail-open.
  } finally {
    fetchInFlight = false;
  }
}

/**
 * Starts the update check (idempotent): hydrate persisted state, derive once, refresh if due, and
 * re-check on every app foreground. Returns a cleanup for the mounting effect.
 */
export function startUpdateCheck(): () => void {
  if (started) {
    return () => {};
  }
  started = true;
  (async () => {
    await hydrate();
    recompute();
    // Foreground re-checks only start once hydration has seeded the throttle state — an early
    // 'active' event must not bypass the persisted 6h throttle or race the cache hydration.
    if (started) {
      appStateSubscription = AppState.addEventListener('change', status => {
        if (status === 'active') {
          refreshUpdateManifest().catch(() => {});
        }
      });
    }
    await refreshUpdateManifest();
  })().catch(() => {
    // Every stage above is fail-open already; this guards the chain itself.
  });
  return () => {
    appStateSubscription?.remove();
    appStateSubscription = null;
    started = false;
  };
}

/** "Later" on the notify banner: never re-prompt for this latest version. */
export function dismissUpdateBanner(): void {
  const latest = platformInfo(decoded)?.latest;
  if (latest == null) {
    return;
  }
  dismissedBannerVersion = latest;
  AsyncStorage.setItem(UPDATE_DISMISSED_BANNER_STORAGE_KEY, latest).catch(() => {
    // Best-effort: worst case the banner shows again next launch.
  });
  recompute();
}

/** Dismisses a broadcast notice by id (re-broadcastable by changing the id server-side). */
export function dismissUpdateNotice(id: string): void {
  if (!dismissedNoticeIds.includes(id)) {
    dismissedNoticeIds = [...dismissedNoticeIds.slice(-(MAX_DISMISSED_NOTICE_IDS - 1)), id];
    AsyncStorage.setItem(
      UPDATE_DISMISSED_NOTICES_STORAGE_KEY,
      JSON.stringify(dismissedNoticeIds),
    ).catch(() => {});
  }
  recompute();
}

/**
 * "Continue anyway" on the blocking screen — session-scoped, deliberately not persisted: the
 * availability-first escape hatch (a custom-broker user on an "unsupported" build may still work)
 * without letting one tap silence a real kill-switch forever.
 */
export function continueDespiteBlock(): void {
  blockOverridden = true;
  recompute();
}

/** Test-only: clears all module state (mirror of resetStoreForTests). */
export function resetUpdateCheckForTests(): void {
  decoded = null;
  lastSuccessAtMs = 0;
  lastAttemptAtMs = 0;
  dismissedBannerVersion = null;
  dismissedNoticeIds = [];
  blockOverridden = false;
  fetchInFlight = false;
  started = false;
  appStateSubscription?.remove();
  appStateSubscription = null;
}
