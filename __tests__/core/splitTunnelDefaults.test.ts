/**
 * Region-aware split-tunnel defaults: the country presets may only ship on inside the country
 * they describe. geosite-cn carries hosts the whole world loads (doubleclick.net,
 * fonts.googleapis.com, www.gstatic.com …), so a false positive outside China puts ordinary page
 * loads on the direct path with the user's real IP while the app reports CONNECTED.
 */
import { bypassCountriesForRegion, deviceRegion } from '../../src/model/splitTunnelDefaults';

/** Stands in for the device's Intl, which is where the location signal comes from. */
function placeDevice(options: { timeZone?: unknown; locale?: unknown }): void {
  jest
    .spyOn(Intl, 'DateTimeFormat')
    .mockImplementation(
      () =>
        ({
          resolvedOptions: () => ({ timeZone: options.timeZone, locale: options.locale }),
        } as unknown as Intl.DateTimeFormat),
    );
}

afterEach(() => {
  jest.restoreAllMocks();
});

describe('bypassCountriesForRegion', () => {
  it('maps only the two regions with a bundled rule set', () => {
    expect(bypassCountriesForRegion('IR')).toEqual(['ir']);
    expect(bypassCountriesForRegion('CN')).toEqual(['cn']);
    expect(bypassCountriesForRegion('ir')).toEqual(['ir']);
  });

  it('is empty everywhere else, including an unknown region', () => {
    for (const region of ['US', 'DE', 'TR', 'HK', 'MO', 'RU', '']) {
      expect(bypassCountriesForRegion(region)).toEqual([]);
    }
  });
});

describe('deviceRegion', () => {
  it('reads the country off the time zone', () => {
    placeDevice({ timeZone: 'Asia/Tehran', locale: 'en-US' });
    expect(deviceRegion()).toBe('IR');

    placeDevice({ timeZone: 'Asia/Shanghai', locale: 'en-US' });
    expect(deviceRegion()).toBe('CN');

    // Legacy aliases a device may still report, and the western-China zones.
    placeDevice({ timeZone: 'Asia/Urumqi', locale: 'en-US' });
    expect(deviceRegion()).toBe('CN');
    placeDevice({ timeZone: 'PRC', locale: 'en-US' });
    expect(deviceRegion()).toBe('CN');
    placeDevice({ timeZone: 'Iran', locale: 'en-US' });
    expect(deviceRegion()).toBe('IR');
  });

  it('lets a real time zone overrule the locale in both directions', () => {
    // The whole point of the fix: a diaspora phone kept in Chinese/Persian is not in China/Iran.
    placeDevice({ timeZone: 'Europe/Berlin', locale: 'zh-Hans-CN' });
    expect(deviceRegion()).toBe('');
    placeDevice({ timeZone: 'America/Los_Angeles', locale: 'fa-IR' });
    expect(deviceRegion()).toBe('');

    // And the converse: a phone in Tehran set to English still gets the Iran preset.
    placeDevice({ timeZone: 'Asia/Tehran', locale: 'en-GB' });
    expect(deviceRegion()).toBe('IR');
  });

  it('leaves Hong Kong and Macau out of the mainland preset', () => {
    placeDevice({ timeZone: 'Asia/Hong_Kong', locale: 'zh-HK' });
    expect(deviceRegion()).toBe('');
    placeDevice({ timeZone: 'Asia/Macau', locale: 'zh-MO' });
    expect(deviceRegion()).toBe('');
  });

  it('never falls back to the locale when the zone carries no location', () => {
    // A language preference is not evidence of physical location. Guessing from it would hand the
    // China preset to exactly the diaspora devices this module protects, so no evidence must mean
    // no preset — a one-tap cost, never a leak.
    for (const timeZone of ['UTC', 'GMT', 'Etc/UTC', 'Etc/GMT+3', 'local', undefined, '', 7]) {
      placeDevice({ timeZone, locale: 'zh-Hans-CN' });
      expect(deviceRegion()).toBe('');
      placeDevice({ timeZone, locale: 'fa-IR' });
      expect(deviceRegion()).toBe('');
    }
  });

  it('returns nothing usable rather than guessing', () => {
    placeDevice({ timeZone: undefined, locale: undefined });
    expect(deviceRegion()).toBe('');

    jest.spyOn(Intl, 'DateTimeFormat').mockImplementation(() => {
      throw new Error('no Intl');
    });
    expect(deviceRegion()).toBe('');
  });
});
