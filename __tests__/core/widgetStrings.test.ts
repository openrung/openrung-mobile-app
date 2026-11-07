/**
 * The iOS widget's Swift string table is GENERATED from the locale tables (`npm run widget:strings`).
 * This re-renders it from the current tables and fails when the committed file drifted — a new
 * translation, a changed status label, or a hand edit on the Swift side.
 */
import { en } from '../../src/i18n/strings/en';
import { ar } from '../../src/i18n/strings/ar';
import { fa } from '../../src/i18n/strings/fa';
import { my } from '../../src/i18n/strings/my';
import { ru } from '../../src/i18n/strings/ru';
import { tr } from '../../src/i18n/strings/tr';
import { vi } from '../../src/i18n/strings/vi';
import { zhCN } from '../../src/i18n/strings/zh-CN';
import { zhTW } from '../../src/i18n/strings/zh-TW';
import {
  WIDGET_STRING_KEYS,
  WIDGET_TAGS,
  renderWidgetStringsSwift,
} from '../../src/i18n/widgetStrings';

// The project ships no Node type declarations (only jest's), so the two Node pieces this test
// needs are declared here rather than pulling in @types/node for one file.
declare const __dirname: string;
declare const require: (id: string) => unknown;
const { readFileSync } = require('fs') as {
  readFileSync: (path: string, encoding: 'utf8') => string;
};
const { join } = require('path') as { join: (...parts: string[]) => string };

const GENERATED = join(
  __dirname,
  '../../ios/OpenRungWidget/WidgetStrings.generated.swift',
);

const tables = {
  en,
  'zh-CN': { ...en, ...zhCN },
  'zh-TW': { ...en, ...zhTW },
  fa: { ...en, ...fa },
  ru: { ...en, ...ru },
  ar: { ...en, ...ar },
  tr: { ...en, ...tr },
  vi: { ...en, ...vi },
  my: { ...en, ...my },
};

describe('iOS widget strings', () => {
  it('committed Swift table matches the locale tables (run npm run widget:strings)', () => {
    expect(readFileSync(GENERATED, 'utf8')).toBe(renderWidgetStringsSwift(tables));
  });

  it('covers the nine supported languages', () => {
    expect([...WIDGET_TAGS]).toEqual([
      'en',
      'zh-CN',
      'zh-TW',
      'fa',
      'ru',
      'ar',
      'tr',
      'vi',
      'my',
    ]);
  });

  it('every widget key is a plain string in every locale (no English fallback)', () => {
    for (const tag of WIDGET_TAGS) {
      for (const key of WIDGET_STRING_KEYS) {
        const override = tag === 'en' ? en : tables[tag];
        expect(typeof (override as Record<string, unknown>)[key]).toBe('string');
      }
    }
  });

  it('refuses to render a locale missing a widget key', () => {
    const broken = { ...tables, fa: { ...tables.fa, widgetName: undefined } };
    expect(() => renderWidgetStringsSwift(broken)).toThrow(/"fa".*"widgetName"/);
  });
});
