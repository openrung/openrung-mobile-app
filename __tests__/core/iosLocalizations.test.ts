/**
 * iOS limits `NSLocale.currentLocale` (which Hermes `Intl` reports as the system locale) to
 * the languages the app bundle declares. A language the app translates but Info.plist does
 * not list in CFBundleLocalizations resolves to English under "System default" on iOS.
 */
jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import { SUPPORTED_TAGS } from '../../src/i18n';

// The app's tsconfig has no Node types; Jest runs these tests under Node.
declare const __dirname: string;
const { readFileSync } = require('fs') as {
  readFileSync: (path: string, encoding: 'utf8') => string;
};

// SUPPORTED_TAGS mapped to iOS localization identifiers.
const IOS_LOCALIZATIONS: Record<(typeof SUPPORTED_TAGS)[number], string> = {
  en: 'en',
  'zh-CN': 'zh-Hans',
  'zh-TW': 'zh-Hant',
  fa: 'fa',
  ru: 'ru',
  ar: 'ar',
  tr: 'tr',
  vi: 'vi',
  my: 'my',
};

function declaredLocalizations(): string[] {
  const plist = readFileSync(
    `${__dirname}/../../ios/OpenRung/Info.plist`,
    'utf8',
  );
  const match = plist.match(
    /<key>CFBundleLocalizations<\/key>\s*<array>([\s\S]*?)<\/array>/,
  );
  if (!match) {
    return [];
  }
  return [...match[1].matchAll(/<string>([^<]+)<\/string>/g)].map(m => m[1]);
}

describe('iOS CFBundleLocalizations', () => {
  it('maps every supported language', () => {
    expect(Object.keys(IOS_LOCALIZATIONS).sort()).toEqual(
      [...SUPPORTED_TAGS].sort(),
    );
  });

  it('declares every language the app translates', () => {
    const declared = declaredLocalizations();
    const missing = Object.values(IOS_LOCALIZATIONS).filter(
      id => !declared.includes(id),
    );
    expect(missing).toEqual([]);
  });
});
