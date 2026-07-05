import { decodeExitIpInfo } from '../../src/net/ipInfoClient';

describe('decodeExitIpInfo', () => {
  it('parses the ipinfo.io shape', () => {
    expect(
      decodeExitIpInfo({
        ip: '203.0.113.10',
        city: 'Tokyo',
        region: 'Tokyo',
        country: 'JP',
        org: 'AS13335 Cloudflare, Inc.',
      }),
    ).toEqual({
      ip: '203.0.113.10',
      city: 'Tokyo',
      country: 'JP',
      org: 'AS13335 Cloudflare, Inc.',
    });
  });

  it('tolerates missing optional fields', () => {
    expect(decodeExitIpInfo({ ip: '198.51.100.7' })).toEqual({
      ip: '198.51.100.7',
      city: null,
      country: null,
      org: null,
    });
  });

  it('treats blank strings as null', () => {
    expect(decodeExitIpInfo({ ip: '198.51.100.7', city: '   ', country: '' })).toMatchObject({
      city: null,
      country: null,
    });
  });

  it('throws when the ip is missing or the payload is not an object', () => {
    expect(() => decodeExitIpInfo({ city: 'Tokyo' })).toThrow(/no ip/);
    expect(() => decodeExitIpInfo(null)).toThrow(/not an object/);
    expect(() => decodeExitIpInfo('nope')).toThrow(/not an object/);
  });
});
