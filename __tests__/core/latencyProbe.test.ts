jest.mock('../../src/native/OpenRungVpn', () => ({
  OpenRungVpn: { measureLatency: jest.fn() },
}));

import { runLatencyProbe } from '../../src/net/latencyProbe';
import type { ExitNodeRegion } from '../../src/model/exitNode';
import type { LatencyMeasurement, LatencyTarget } from '../../src/native/types';

function region(overrides: Partial<ExitNodeRegion> & Pick<ExitNodeRegion, 'countryCode'>): ExitNodeRegion {
  return {
    countryName: overrides.countryName ?? overrides.countryCode,
    city: overrides.city ?? null,
    latitude: 0,
    longitude: 0,
    nodeCount: 1,
    probeTargets: [{ host: '203.0.113.10', port: 443 }],
    ...overrides,
  };
}

describe('runLatencyProbe', () => {
  it('returns the minimum reachable RTT per region', async () => {
    const jp = region({ countryCode: 'JP', city: 'Tokyo', probeTargets: [
      { host: 'a', port: 443 },
      { host: 'b', port: 443 },
    ] });
    const measure = jest.fn(async (targets: LatencyTarget[]): Promise<LatencyMeasurement> => {
      expect(targets.map(t => t.id)).toEqual(['JP|Tokyo#0', 'JP|Tokyo#1']);
      return {
        viaTunnel: false,
        results: [
          { id: 'JP|Tokyo#0', latencyMs: 180, reachable: true },
          { id: 'JP|Tokyo#1', latencyMs: 90, reachable: true },
        ],
      };
    });
    const results = await runLatencyProbe([jp], measure);
    expect(results).toEqual({ 'JP|Tokyo': { regionKey: 'JP|Tokyo', rttMs: 90 } });
  });

  it('marks a region unreachable only when every probe fails', async () => {
    const de = region({ countryCode: 'DE', city: 'Berlin', probeTargets: [
      { host: 'a', port: 443 },
      { host: 'b', port: 443 },
    ] });
    const measure = async (): Promise<LatencyMeasurement> => ({
      viaTunnel: false,
      results: [
        { id: 'DE|Berlin#0', latencyMs: null, reachable: false },
        { id: 'DE|Berlin#1', latencyMs: null, reachable: false },
      ],
    });
    const results = await runLatencyProbe([de], measure);
    expect(results).toEqual({ 'DE|Berlin': { regionKey: 'DE|Berlin', rttMs: null } });
  });

  it('keeps the reachable probe when one of a pair times out', async () => {
    const us = region({ countryCode: 'US', probeTargets: [
      { host: 'a', port: 443 },
      { host: 'b', port: 443 },
    ] });
    const measure = async (): Promise<LatencyMeasurement> => ({
      viaTunnel: false,
      results: [
        { id: 'US|#0', latencyMs: null, reachable: false },
        { id: 'US|#1', latencyMs: 140, reachable: true },
      ],
    });
    const results = await runLatencyProbe([us], measure);
    expect(results['US|'].rttMs).toBe(140);
  });

  it('skips the native call entirely when there are no targets', async () => {
    const measure = jest.fn();
    const results = await runLatencyProbe([], measure as never);
    expect(results).toEqual({});
    expect(measure).not.toHaveBeenCalled();
  });
});
