/**
 * Which recents entry describes the connected relay, and where the home map marks it.
 */
import {
  connectedRelayLngLat,
  sessionRecent,
  type ExitNodeRegion,
} from '../../src/model/exitNode';

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

describe('sessionRecent', () => {
  const head = { relayName: 'proud-falcon', label: 'Osaka, Japan', countryCode: 'JP' };
  const older = { relayName: 'calm-otter', label: 'Seoul, South Korea', countryCode: 'KR' };

  it('is the head of the recents when it names this relay at this location', () => {
    expect(sessionRecent('proud-falcon', 'Osaka, Japan', [head, older])).toBe(head);
  });

  it('ignores an older entry for the relay', () => {
    expect(sessionRecent('calm-otter', 'Seoul, South Korea', [head, older])).toBeNull();
  });

  it('rejects a same-named relay somewhere else', () => {
    // An unlocated relay adds no entry, so the head is still the previous session's; two
    // relays may share an operator-chosen name.
    expect(sessionRecent('proud-falcon', 'Unknown location', [head, older])).toBeNull();
    expect(sessionRecent('proud-falcon', 'Frankfurt, Germany', [head, older])).toBeNull();
  });

  it('is null without a name, a location or any recents', () => {
    expect(sessionRecent(null, 'Osaka, Japan', [head])).toBeNull();
    expect(sessionRecent('proud-falcon', null, [head])).toBeNull();
    expect(sessionRecent('proud-falcon', 'Osaka, Japan', [])).toBeNull();
  });
});
