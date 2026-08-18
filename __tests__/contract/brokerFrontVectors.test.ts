/**
 * The TypeScript half of the shared broker-front snapshot.
 *
 * This repo owns no racing: it hands native brokerapi a single primary and Go races the built-in
 * candidates, so the phases and the candidate ordering in the vectors are the Go suite's to assert
 * and deliberately not checked here. What is checked is the claim this side can actually make —
 * that every front this app hardcodes still appears in the canonical list — which is what catches
 * a front rotated in openrung and not here, the case where a blocked user quietly loses a
 * fallback.
 */
import vectors from '../../testdata/contract/broker_fronts.json';
import { AppConfig } from '../../src/config';

const EXPECTED_VERSION = 1;
const SUITE = 'ts';

describe('broker front contract vectors', () => {
  it('runs the version and the suite it was written for', () => {
    expect(vectors.version).toBe(EXPECTED_VERSION);
    expect(vectors.suites).toContain(SUITE);
  });

  it('configures a primary that is one of the canonical fronts', () => {
    expect(vectors.default_order).toContain(AppConfig.DEFAULT_BROKER_URL);
  });

  it('posts telemetry to a canonical front', () => {
    // A telemetry target off the canonical list would send the pre-VPN IP and the stable client id
    // somewhere the directory contract never vouched for.
    expect(vectors.default_order).toContain(AppConfig.TELEMETRY_BROKER_URL);
  });

  it('keeps the canonical list non-empty and free of duplicates', () => {
    expect(vectors.default_order.length).toBeGreaterThan(0);
    expect(new Set(vectors.default_order).size).toBe(vectors.default_order.length);
  });

  it('leaves the phase ordering to the suite that implements it', () => {
    // Guard against this suite growing assertions it cannot honestly make: the phases describe
    // brokerapi's race, which no TypeScript here performs.
    const phased = vectors.phases.flatMap(phase => phase.urls);
    expect([...phased].sort()).toEqual([...vectors.default_order].sort());
  });

  it('does not confuse the directory fronts with the update-manifest channel', () => {
    // Separate channel with its own candidate list and its own check (npm run transport:check).
    // Conflating them would let a manifest-only host look like an approved directory front.
    const manifestOnly = AppConfig.UPDATE_MANIFEST_URLS.filter(
      url => !vectors.default_order.some(front => url.startsWith(front)),
    );
    expect(manifestOnly.length).toBeGreaterThan(0);
  });
});
