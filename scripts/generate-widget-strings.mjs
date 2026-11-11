#!/usr/bin/env node
// Renders ios/OpenRungWidget/WidgetStrings.generated.swift from the app's locale tables so the iOS
// home-screen widget shows the same copy as the app in every supported language.
//
// Run: npm run widget:strings
// The script imports the .ts tables directly. Node strips TypeScript types by default only from
// 22.18 / 23.6, and the repo's floor is 22.11, so the npm script passes --experimental-strip-types
// (accepted, and redundant, on newer versions).
// Drift check: __tests__/core/widgetStrings.test.ts re-renders and compares with the committed file.

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = async (relative) => import(pathToFileURL(join(root, relative)).href);

const { renderWidgetStringsSwift, WIDGET_TAGS } = await load('src/i18n/widgetStrings.ts');
const { en } = await load('src/i18n/strings/en.ts');

const overrides = {
  en: {},
  'zh-CN': (await load('src/i18n/strings/zh-CN.ts')).zhCN,
  'zh-TW': (await load('src/i18n/strings/zh-TW.ts')).zhTW,
  fa: (await load('src/i18n/strings/fa.ts')).fa,
  ru: (await load('src/i18n/strings/ru.ts')).ru,
  ar: (await load('src/i18n/strings/ar.ts')).ar,
  tr: (await load('src/i18n/strings/tr.ts')).tr,
  vi: (await load('src/i18n/strings/vi.ts')).vi,
  my: (await load('src/i18n/strings/my.ts')).my,
};

const tables = Object.fromEntries(WIDGET_TAGS.map((tag) => [tag, { ...en, ...overrides[tag] }]));
const output = join(root, 'ios/OpenRungWidget/WidgetStrings.generated.swift');
writeFileSync(output, renderWidgetStringsSwift(tables));
console.log(`✓ wrote ${output}`);
