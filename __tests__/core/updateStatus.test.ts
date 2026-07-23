/**
 * Tier-ladder derivation (src/model/updateStatus.ts): blocked/notify require a VERIFIED
 * manifest, unsigned tops out at the passive row, "Continue anyway" downgrades a block, and
 * notices filter on verification, dismissal and expiry.
 */
import {
  INITIAL_UPDATE_UI,
  deriveUpdateUiState,
  pickLocalizedText,
  type DeriveUpdateInputs,
} from '../../src/model/updateStatus';
import type {
  DecodedUpdateManifest,
  UpdateManifest,
  UpdateNotice,
} from '../../src/net/updateManifestClient';

const NOW = Date.parse('2026-07-22T12:00:00Z');

function manifest(overrides: Partial<UpdateManifest> = {}): UpdateManifest {
  return {
    generatedAtMs: NOW - 3_600_000,
    android: { latest: '0.4.0', minSupported: null },
    ios: { latest: '0.4.0', minSupported: null },
    promote: 'silent',
    notice: null,
    ...overrides,
  };
}

function notice(overrides: Partial<UpdateNotice> = {}): UpdateNotice {
  return {
    id: 'n1',
    level: 'warn',
    title: { en: 'Title' },
    body: { en: 'Body' },
    url: null,
    expiresMs: null,
    ...overrides,
  };
}

function derive(
  decoded: DecodedUpdateManifest | null,
  overrides: Partial<DeriveUpdateInputs> = {},
) {
  return deriveUpdateUiState({
    decoded,
    platform: 'android',
    currentVersion: '0.3.2',
    dismissedBannerVersion: null,
    dismissedNoticeIds: [],
    blockOverridden: false,
    nowMs: NOW,
    ...overrides,
  });
}

const verified = (m: UpdateManifest): DecodedUpdateManifest => ({
  manifest: m,
  verified: true,
  keyIdUsed: 'test',
});
const unsigned = (m: UpdateManifest): DecodedUpdateManifest => ({
  manifest: m,
  verified: false,
  keyIdUsed: null,
});

describe('deriveUpdateUiState — version tiers', () => {
  it('no manifest -> initial state', () => {
    expect(derive(null)).toEqual(INITIAL_UPDATE_UI);
  });

  it('up to date -> none', () => {
    expect(derive(verified(manifest()), { currentVersion: '0.4.0' }).tier).toBe('none');
  });

  it('ahead of latest (dev build) -> none', () => {
    expect(derive(verified(manifest()), { currentVersion: '9.9.9' }).tier).toBe('none');
  });

  it('behind, promote silent -> available', () => {
    const ui = derive(verified(manifest()));
    expect(ui.tier).toBe('available');
    expect(ui.latestVersion).toBe('0.4.0');
    expect(ui.verified).toBe(true);
  });

  it('behind, promote notify, verified -> notify (once per version)', () => {
    const m = manifest({ promote: 'notify' });
    expect(derive(verified(m)).tier).toBe('notify');
    expect(derive(verified(m), { dismissedBannerVersion: '0.4.0' }).tier).toBe('available');
    // A NEWER latest re-arms the banner after a dismissal of the old one.
    const newer = manifest({ promote: 'notify', android: { latest: '0.5.0', minSupported: null } });
    expect(derive(verified(newer), { dismissedBannerVersion: '0.4.0' }).tier).toBe('notify');
  });

  it('unsigned manifests top out at available — no banner, no block', () => {
    expect(derive(unsigned(manifest({ promote: 'notify' }))).tier).toBe('available');
    const floored = manifest({ android: { latest: '0.4.0', minSupported: '0.4.0' } });
    expect(derive(unsigned(floored)).tier).toBe('available');
  });

  it('below the floor, verified -> blocked; Continue anyway -> available', () => {
    const floored = manifest({ android: { latest: '0.4.0', minSupported: '0.4.0' } });
    expect(derive(verified(floored)).tier).toBe('blocked');
    expect(derive(verified(floored), { blockOverridden: true }).tier).toBe('available');
  });

  it('Continue anyway lands on available even when promote is notify (no second prompt)', () => {
    const floored = manifest({
      promote: 'notify',
      android: { latest: '0.4.0', minSupported: '0.4.0' },
    });
    expect(derive(verified(floored), { blockOverridden: true }).tier).toBe('available');
  });

  it('floor without latest still blocks, with latestVersion null', () => {
    const floored = manifest({ android: { latest: null, minSupported: '0.4.0' } });
    const ui = derive(verified(floored));
    expect(ui.tier).toBe('blocked');
    expect(ui.latestVersion).toBeNull();
  });

  it('unparseable current version derives no version tier (fail open)', () => {
    expect(derive(verified(manifest()), { currentVersion: 'dev' }).tier).toBe('none');
  });

  it('uses the matching platform section only', () => {
    const iosOnly = manifest({ android: null });
    expect(derive(verified(iosOnly)).tier).toBe('none');
    expect(derive(verified(iosOnly), { platform: 'ios' }).tier).toBe('available');
    expect(derive(verified(iosOnly), { platform: 'windows' }).tier).toBe('none');
  });
});

describe('deriveUpdateUiState — notices', () => {
  it('shows a verified, undismissed, unexpired notice (even when up to date)', () => {
    const ui = derive(verified(manifest({ notice: notice() })), { currentVersion: '0.4.0' });
    expect(ui.tier).toBe('none');
    expect(ui.notice?.id).toBe('n1');
  });

  it('never shows notices from unsigned manifests', () => {
    expect(derive(unsigned(manifest({ notice: notice() }))).notice).toBeNull();
  });

  it('filters dismissed ids and expired notices', () => {
    const m = manifest({ notice: notice() });
    expect(derive(verified(m), { dismissedNoticeIds: ['n1'] }).notice).toBeNull();
    const expired = manifest({ notice: notice({ expiresMs: NOW - 1 }) });
    expect(derive(verified(expired)).notice).toBeNull();
    const live = manifest({ notice: notice({ expiresMs: NOW + 1 }) });
    expect(derive(verified(live)).notice?.id).toBe('n1');
  });
});

describe('pickLocalizedText', () => {
  const map = { en: 'english', 'zh-CN': 'simplified', zh: 'chinese', fa: 'persian' };

  it('prefers the exact tag', () => {
    expect(pickLocalizedText(map, 'zh-CN')).toBe('simplified');
    expect(pickLocalizedText(map, 'fa')).toBe('persian');
  });

  it('falls back to the primary subtag, then English', () => {
    expect(pickLocalizedText(map, 'zh-TW')).toBe('chinese');
    expect(pickLocalizedText(map, 'ru')).toBe('english');
  });
});
