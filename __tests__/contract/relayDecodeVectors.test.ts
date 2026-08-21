/**
 * The TypeScript half of the shared relay-decode contract.
 *
 * The rows come from testdata/contract/relay_decode.json, vendored from openrung/openrung and
 * checked against the pinned ref by `npm run contract:check`. The same rows run against Go's
 * decoder and selector in that repo, so a divergence here is a real disagreement between two
 * clients about which relays a user can reach — not a stale local fixture.
 */
import vectors from '../../testdata/contract/relay_decode.json';
import {
  effectiveNodeClass,
  isUsable,
  orderedCandidates,
  selectFirstUsable,
  serverTimeMs,
} from '../../src/model/relay';
import type { RelayDescriptor, RelayListResponse } from '../../src/model/relay';

/** The version this suite was written against; bumping the file means revisiting these tests. */
const EXPECTED_VERSION = 3;

/** This suite's identifier in the file's `suites` declaration. */
const SUITE = 'ts';

type VectorCase = (typeof vectors)['cases'][number];

function response(testCase: VectorCase): RelayListResponse {
  return testCase.body as unknown as RelayListResponse;
}

describe('relay decode contract vectors', () => {
  it('runs the version and the suite it was written for', () => {
    expect(vectors.version).toBe(EXPECTED_VERSION);
    expect(vectors.suites).toContain(SUITE);
  });

  it('covers every case in the file', () => {
    // Guards the failure mode the vectors exist to prevent: a suite that iterates the rows,
    // asserts nothing, and reports green. If a case is added upstream, this count moves and the
    // suite has to be looked at rather than silently skipping it.
    expect(vectors.cases.map(testCase => testCase.id)).toEqual([
      'api_two_relays',
      'unusable_mix',
      'forward_compatible',
    ]);
  });

  describe.each(vectors.cases.map(testCase => [testCase.id, testCase] as const))(
    '%s',
    (_id, testCase) => {
      const decoded = response(testCase);

      it('decodes the signed envelope', () => {
        const expected = testCase.expect;
        expect(decoded.count).toBe(expected.count);
        expect(decoded.server_time).toBe(expected.server_time);
        expect(decoded.not_after).toBe(expected.not_after);
        expect(decoded.key_id).toBe(expected.key_id);
        expect(decoded.channel).toBe(expected.channel);
        expect(decoded.limit).toBe(expected.limit);
        // serverTimeMs must parse what the broker actually sends.
        expect(serverTimeMs(decoded)).toBe(Date.parse(expected.server_time));
      });

      it('decodes each descriptor', () => {
        const expected = testCase.expect as {
          relays?: Record<string, unknown>[];
          relay_ids?: string[];
        };

        if (expected.relay_ids) {
          // Broker order is preserved: the filter is score-free and never reorders.
          expect(decoded.relays.map(relay => relay.id)).toEqual(expected.relay_ids);
          return;
        }

        expect(decoded.relays).toHaveLength(expected.relays!.length);
        expected.relays!.forEach((want, index) => {
          const relay = decoded.relays[index] as unknown as Record<string, unknown>;
          for (const [field, value] of Object.entries(want)) {
            if (field === 'effective_node_class') {
              expect(effectiveNodeClass(relay.node_class as string | undefined)).toBe(value);
              continue;
            }
            // Fields this model does not carry are another suite's to assert: `relay_version` is
            // the canonical name and the TypeScript model exposes only the legacy wire name, and
            // `wss_fronts` is consumed by the native tunnel layer, never declared on
            // RelayDescriptor. Asserting them here would only pass through the untyped cast and
            // fake coverage the TypeScript decoder does not have.
            if (field === 'relay_version' || field === 'wss_fronts') {
              continue;
            }
            if (value === null) {
              // null means "absent on the wire"; TypeScript's no-value representation is undefined.
              expect(relay[field]).toBeUndefined();
              continue;
            }
            expect(relay[field]).toEqual(value);
          }
        });
      });

      it.each(testCase.usability.map(probe => [probe.now, probe] as const))(
        'filters and selects at %s',
        (_now, probe) => {
          const now = Date.parse(probe.now);
          const relays = decoded.relays as RelayDescriptor[];

          expect(relays.filter(relay => isUsable(relay, now)).map(relay => relay.id)).toEqual(
            probe.usable_ids,
          );
          expect(orderedCandidates(relays, now).map(relay => relay.id)).toEqual(probe.usable_ids);
          expect(selectFirstUsable(relays, now)?.id ?? null).toBe(probe.first_usable_id ?? null);
        },
      );
    },
  );

  it('leaves the wire-schema rejections to the suites that own them', () => {
    // The invalid bodies are rejected by native brokerapi before any TypeScript sees them, so this
    // suite must not be listed as one of their consumers.
    expect(vectors.invalid.suites).not.toContain(SUITE);
  });
});
