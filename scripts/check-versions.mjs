#!/usr/bin/env node
// Enforces that the app version string stays single-sourced in package.json.
//
// Three surfaces derive their version from package.json at build time and therefore cannot
// drift: src/config.ts (imports it), android/app/build.gradle (JsonSlurper), and
// ios/project.yml (${APP_VERSION} expanded by scripts/generate-project.sh). The one place a
// stale copy can be committed is the *generated* iOS pbxproj, so we check that against the
// canonical value — and we assert the derived surfaces still derive (no re-hardcoding).
//
// Run: node scripts/check-versions.mjs   (also wired into .github/workflows/version-check.yml)

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');

const canonical = JSON.parse(read('package.json')).version;
const errors = [];

// iOS: the generated pbxproj bakes MARKETING_VERSION; every entry must match package.json.
const pbxproj = read('ios/OpenRung.xcodeproj/project.pbxproj');
const marketing = [...pbxproj.matchAll(/MARKETING_VERSION = ([^;]+);/g)].map((m) => m[1].trim());
if (marketing.length === 0) {
  errors.push('ios pbxproj: no MARKETING_VERSION found (did the project fail to generate?)');
}
for (const v of new Set(marketing)) {
  if (v !== canonical) {
    errors.push(
      `ios MARKETING_VERSION "${v}" != package.json "${canonical}" — run ios/scripts/generate-project.sh and commit the regenerated project`,
    );
  }
}

// Android: versionName must derive from package.json, never be a hardcoded literal.
const gradle = read('android/app/build.gradle');
const gradleLiteral = gradle.match(/versionName\s+["']([^"']+)["']/);
if (gradleLiteral) {
  errors.push(
    `android/app/build.gradle hardcodes versionName "${gradleLiteral[1]}" — it must derive from package.json (def appVersionName)`,
  );
}

// JS: APP_VERSION must derive from package.json, never be a hardcoded literal.
const config = read('src/config.ts');
const configLiteral = config.match(/APP_VERSION\s*=\s*['"]([^'"]+)['"]/);
if (configLiteral) {
  errors.push(
    `src/config.ts hardcodes APP_VERSION "${configLiteral[1]}" — it must import { version } from '../package.json'`,
  );
}

if (errors.length) {
  console.error(`✖ Version sources out of sync with package.json (${canonical}):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log(`✓ All version sources single-sourced from package.json (${canonical}).`);
