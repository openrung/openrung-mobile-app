import { centroid, COUNTRY_GEO_SIZE, displayName } from '../../src/model/countryGeo';

describe('countryGeo', () => {
  it('carries the full curated table ported from CountryGeo.kt', () => {
    expect(COUNTRY_GEO_SIZE).toBe(51);
  });

  it('resolves centroids case-insensitively with trimming', () => {
    expect(centroid('JP')).toEqual({ name: 'Japan', latitude: 36.2, longitude: 138.25 });
    expect(centroid('jp')).toEqual(centroid('JP'));
    expect(centroid('  us ')).toEqual({
      name: 'United States',
      latitude: 39.0,
      longitude: -98.0,
    });
  });

  it('returns null for unknown codes', () => {
    expect(centroid('ZZ')).toBeNull();
    expect(centroid('')).toBeNull();
  });

  it('resolves display names', () => {
    expect(displayName('KR')).toBe('South Korea');
    expect(displayName('tw')).toBe('Taiwan');
    expect(displayName('XX')).toBeNull();
  });

  it('covers the APAC-dense set plus common exits', () => {
    for (const code of ['SG', 'VN', 'MM', 'IR', 'RU', 'DE', 'SE', 'TL', 'QA']) {
      expect(centroid(code)).not.toBeNull();
    }
  });
});
