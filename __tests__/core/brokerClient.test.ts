import { candidates, relayListUrl } from '../../src/net/brokerClient';

describe('relayListUrl', () => {
  it('builds the relay list URL from a bare base', () => {
    expect(relayListUrl('https://broker.openrung.org/', 5)).toBe(
      'https://broker.openrung.org/api/v1/relays?limit=5',
    );
  });

  it('keeps an explicit port and cleartext scheme', () => {
    expect(relayListUrl('http://54.238.185.205:8080/', 20)).toBe(
      'http://54.238.185.205:8080/api/v1/relays?limit=20',
    );
  });

  it('preserves an existing base path', () => {
    expect(relayListUrl('https://example.com/base/', 5)).toBe(
      'https://example.com/base/api/v1/relays?limit=5',
    );
    expect(relayListUrl('https://example.com/base/deep', 7)).toBe(
      'https://example.com/base/deep/api/v1/relays?limit=7',
    );
  });

  it('replaces an existing limit param and keeps other params', () => {
    expect(relayListUrl('https://example.com/?limit=99&foo=bar', 5)).toBe(
      'https://example.com/api/v1/relays?foo=bar&limit=5',
    );
  });

  it('coerces limit < 1 to 5', () => {
    expect(relayListUrl('https://example.com/', 0)).toBe(
      'https://example.com/api/v1/relays?limit=5',
    );
    expect(relayListUrl('https://example.com/', -3)).toBe(
      'https://example.com/api/v1/relays?limit=5',
    );
  });

  it('rejects blank or scheme-less URLs', () => {
    expect(() => relayListUrl('   ', 5)).toThrow('broker URL is required');
    expect(() => relayListUrl('broker.openrung.org', 5)).toThrow(
      'broker URL must include scheme and host',
    );
  });
});

describe('candidates', () => {
  const fallbacks = ['https://broker.openrung.org/', 'http://54.238.185.205:8080/'];

  it('puts a genuine primary override first, then the fallbacks', () => {
    expect(candidates('https://my-broker.example/', fallbacks)).toEqual([
      'https://my-broker.example/',
      'https://broker.openrung.org/',
      'http://54.238.185.205:8080/',
    ]);
  });

  it('does NOT let a primary that echoes a fallback reorder the HTTPS-first defaults', () => {
    expect(candidates('http://54.238.185.205:8080/', fallbacks)).toEqual(fallbacks);
    expect(candidates('https://broker.openrung.org/', fallbacks)).toEqual(fallbacks);
  });

  it('trims the primary before comparing against fallbacks', () => {
    expect(candidates('  https://broker.openrung.org/  ', fallbacks)).toEqual(fallbacks);
  });

  it('drops blank entries and de-duplicates while preserving order', () => {
    expect(candidates(null, ['  ', 'https://a/', 'https://a/', 'https://b/'])).toEqual([
      'https://a/',
      'https://b/',
    ]);
    expect(candidates('', fallbacks)).toEqual(fallbacks);
  });
});
