/**
 * Locale coverage guard. `stringsForTag` merges `{ ...en, ...override }`, so any key a
 * locale forgets silently renders in English — which is exactly how the Settings/About
 * strings drifted out of translation. These tests fail loudly the moment a locale falls
 * behind `en`, so new keys must be translated everywhere before they can land.
 *
 * Imports the raw string tables (pure data, `import type` only) rather than ../../src/i18n,
 * which would pull the store and require an AsyncStorage mock.
 */
import { en, type Strings } from '../../src/i18n/strings/en';
import { ar } from '../../src/i18n/strings/ar';
import { fa } from '../../src/i18n/strings/fa';
import { my } from '../../src/i18n/strings/my';
import { ru } from '../../src/i18n/strings/ru';
import { tr } from '../../src/i18n/strings/tr';
import { vi } from '../../src/i18n/strings/vi';
import { zhCN } from '../../src/i18n/strings/zh-CN';
import { zhTW } from '../../src/i18n/strings/zh-TW';

// Every non-English locale in SUPPORTED_TAGS. A new locale must be registered here.
const overrides: Record<string, Partial<Strings>> = {
  'zh-CN': zhCN,
  'zh-TW': zhTW,
  fa,
  ru,
  ar,
  tr,
  vi,
  my,
};

const enKeys = Object.keys(en) as (keyof Strings)[];

describe('i18n locale coverage', () => {
  for (const [tag, override] of Object.entries(overrides)) {
    describe(tag, () => {
      it('translates every key in en (no English fallback)', () => {
        const missing = enKeys.filter(key => !(key in override));
        expect(missing).toEqual([]);
      });

      it('defines no key that is absent from en (guards typos/renames)', () => {
        const extra = Object.keys(override).filter(key => !(key in en));
        expect(extra).toEqual([]);
      });

      it('matches en value kinds (plain string vs. formatter function)', () => {
        const mismatched = enKeys.filter(
          key => typeof override[key] !== typeof en[key],
        );
        expect(mismatched).toEqual([]);
      });
    });
  }
});
