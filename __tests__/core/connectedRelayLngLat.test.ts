/**
 * connectedRelayLngLat: where the home map marks the session's relay — the directory's marker
 * for it when listed, else the coordinates native recorded with the recent entry.
 */
import { connectedRelayLngLat, type ExitNodeRegion } from '../../src/model/exitNode';

const REGIONS: ExitNodeRegion[] = [
  {
    countryCode: 'JP',
    countryName: 'Japan',
    city: 'Osaka',
    latitude: 34.69,
    longitude: 135.5,
    nodeCount: 1,
    relays: [{ id: 'relay_osaka', label: 'proud-falcon', nodeClass: 'foundation' }],
  },
];

describe('connectedRelayLngLat', () => {
  it('is null while there is no session', () => {
    expect(connectedRelayLngLat(null, REGIONS)).toBeNull();
  });

  it("uses the listed relay's marker, not the recorded country centroid", () => {
    const recent = { relayId: 'relay_osaka', latitude: 36.2, longitude: 138.25 };
    expect(connectedRelayLngLat(recent, REGIONS)).toEqual([135.5, 34.69]);
  });

  it('falls back to the recorded coordinates when the directory does not list the relay', () => {
    const recent = { relayId: 'relay_gone', latitude: 36.2, longitude: 138.25 };
    expect(connectedRelayLngLat(recent, REGIONS)).toEqual([138.25, 36.2]);
    expect(connectedRelayLngLat(recent, [])).toEqual([138.25, 36.2]);
  });

  it('is null for an unlocated relay (recorded at 0,0)', () => {
    expect(connectedRelayLngLat({ relayId: 'relay_gone', latitude: 0, longitude: 0 }, REGIONS)).toBeNull();
  });
});
