#!/usr/bin/env node

/**
 * Guard for the contract vectors vendored in testdata/contract.
 *
 * They are copies. openrung/openrung's connectcore/contract/vectors is the source of truth, and a copy that
 * drifts from it is worse than no copy at all: the Kotlin, Swift, and Jest suites keep passing
 * against expectations the Go side has already moved on from, which reads as agreement between
 * four clients that no longer agree.
 *
 * Two halves, because they fail differently:
 *
 *   local   the vendored bytes still hash to the digests in pin.json, the recorded version matches
 *           the version inside each file, and every non-go suite the file declares is either wired
 *           up here or listed as pending with a reason. No network.
 *   remote  the vendored bytes are byte-identical to the pinned openrung ref. Needs network.
 *
 * Both run by default. `--offline` runs the local half only and says so on stderr — the point of
 * the flag is a dev machine without network, not a way to make CI quiet, so it never downgrades a
 * real mismatch into a pass.
 *
 * Usage: node scripts/check-contract-vectors.mjs [--offline] [--sync]
 *        --sync rewrites the vendored copies and digests from the pinned ref.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const vectorDir = path.join(root, 'testdata/contract');
const pinPath = path.join(vectorDir, 'pin.json');

const offline = process.argv.includes('--offline');
const sync = process.argv.includes('--sync');
const failures = [];
const notes = [];

function fail(message) {
  failures.push(message);
}

function digest(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function rawURL(pin, file) {
  return `https://raw.githubusercontent.com/${pin.repo}/${pin.ref}/${pin.source_dir}/${file}`;
}

async function fetchUpstream(pin, file) {
  const url = rawURL(pin, file);
  // Fail fast on a hung connection rather than riding out the CI job timeout.
  const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) {
    throw new Error(`GET ${url} -> HTTP ${response.status}`);
  }
  return Buffer.from(await response.arrayBuffer());
}

const pin = JSON.parse(fs.readFileSync(pinPath, 'utf8'));
const pinned = Object.keys(pin.files);
// A 40-hex ref is an opaque commit worth truncating in messages; a tag name is not.
const refLabel = /^[0-9a-f]{40}$/.test(pin.ref) ? pin.ref.slice(0, 12) : pin.ref;

// The Go binding compiles against the connectcore release pinned in
// android/punchbridge/go.mod, and that release embeds these same vectors — so the copies the
// Kotlin, Swift, and Jest suites read must come from that exact tag, or the non-Go suites test a
// different contract than the binding actually ships. The expected ref is derived from go.mod
// rather than recorded twice; bumping connectcore there means moving pin.json's ref to the
// matching tag and running `npm run contract:sync` in the same change. No network needed: this is
// part of the local half.
const goMod = fs.readFileSync(path.join(root, 'android/punchbridge/go.mod'), 'utf8');
const connectcore = goMod.match(/^\s*github\.com\/openrung\/openrung\/connectcore\s+v(\S+)\s*$/m);
if (!connectcore) {
  fail('android/punchbridge/go.mod has no require for github.com/openrung/openrung/connectcore');
} else if (pin.ref !== `connectcore/v${connectcore[1]}`) {
  fail(
    `pin.json ref "${pin.ref}" does not match android/punchbridge/go.mod's connectcore ` +
      `v${connectcore[1]} (want "connectcore/v${connectcore[1]}"). Move the ref together with ` +
      'go.mod, then re-vendor with `npm run contract:sync`.',
  );
}
if (sync && failures.length > 0) {
  console.error(`contract:sync refused: ${failures.join('; ')}`);
  process.exit(2);
}

// Bytes already downloaded this run (by --sync), so the remote half below never fetches twice.
const upstreamCache = new Map();

// --sync refreshes the copies before anything is checked, so a sync run ends green only if the
// result also satisfies every check below. It fetches and validates everything before writing
// anything: a partial sync — some files rewritten, pin.json still holding the old digests — would
// point the next contract:check's remediation text back at the sync that broke the tree.
if (sync) {
  if (offline) {
    console.error('--sync needs the network; drop --offline.');
    process.exit(2);
  }
  try {
    await Promise.all(
      pinned.map(async file => {
        const upstream = await fetchUpstream(pin, file);
        let parsed;
        try {
          parsed = JSON.parse(upstream.toString('utf8'));
        } catch (error) {
          throw new Error(`${file}: upstream copy is not valid JSON (${error.message})`);
        }
        if (typeof parsed.version !== 'number' || !Array.isArray(parsed.suites)) {
          throw new Error(
            `${file}: upstream copy lacks the version/suites fields the pin records`,
          );
        }
        upstreamCache.set(file, { upstream, parsed });
      }),
    );
  } catch (error) {
    console.error(`contract:sync failed, leaving the tree untouched: ${error.message}`);
    process.exit(2);
  }
  for (const file of pinned) {
    const { upstream, parsed } = upstreamCache.get(file);
    fs.writeFileSync(path.join(vectorDir, file), upstream);
    pin.files[file].sha256 = digest(upstream);
    pin.files[file].version = parsed.version;
    pin.files[file].suites = parsed.suites;
    notes.push(`synced ${file} from ${refLabel}`);
  }
  fs.writeFileSync(pinPath, `${JSON.stringify(pin, null, 2)}\n`);
}

// The directory must hold exactly the pinned files plus pin.json: an unpinned vector file would be
// consumed by the suites while nothing checked it against upstream.
const present = fs
  .readdirSync(vectorDir)
  .filter(name => name.endsWith('.json') && name !== 'pin.json')
  .sort();
const declared = [...pinned].sort();
if (present.join() !== declared.join()) {
  fail(`testdata/contract holds [${present}] but pin.json pins [${declared}]`);
}

for (const [file, expected] of Object.entries(pin.files)) {
  const filePath = path.join(vectorDir, file);
  if (!fs.existsSync(filePath)) {
    fail(`${file}: pinned but not vendored`);
    continue;
  }
  const bytes = fs.readFileSync(filePath);
  const actual = digest(bytes);
  if (actual !== expected.sha256) {
    fail(
      `${file}: sha256 ${actual} does not match pin.json's ${expected.sha256}. ` +
        'Edit the vectors in openrung/openrung, then re-vendor with `npm run contract:sync`.',
    );
    continue;
  }

  let parsed;
  try {
    parsed = JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    fail(`${file}: not valid JSON (${error.message})`);
    continue;
  }
  if (parsed.version !== expected.version) {
    fail(`${file}: carries version ${parsed.version} but pin.json records ${expected.version}`);
  }
  const declaredSuites = Array.isArray(parsed.suites) ? parsed.suites : [];
  if (!Array.isArray(parsed.suites)) {
    fail(`${file}: declares no suites array, so its consumers cannot be accounted for`);
  } else if (parsed.suites.join() !== (expected.suites ?? []).join()) {
    fail(`${file}: declares suites [${parsed.suites}] but pin.json records [${expected.suites}]`);
  }

  // Every suite the file declares, other than the Go one that lives in openrung, must be accounted
  // for here — wired up, or pending with a reason. Silence is what lets a declared consumer look
  // like coverage it is not.
  const pendingSuites = Object.keys(expected.pending_suites ?? {});
  for (const suite of declaredSuites.filter(name => name !== 'go')) {
    const wired = (expected.local_suites ?? []).includes(suite);
    const pending = pendingSuites.includes(suite);
    if (!wired && !pending) {
      fail(
        `${file}: declares suite "${suite}", which this repo neither runs (local_suites) nor ` +
          'records as pending with a reason (pending_suites)',
      );
    }
    if (wired && pending) {
      fail(`${file}: suite "${suite}" is listed as both wired and pending`);
    }
  }
  for (const [suite, reason] of Object.entries(expected.pending_suites ?? {})) {
    if (!declaredSuites.includes(suite)) {
      fail(`${file}: pending suite "${suite}" is not one the file declares`);
    }
    if (typeof reason !== 'string' || reason.trim() === '') {
      fail(`${file}: pending suite "${suite}" carries no reason`);
    }
  }
  for (const suite of expected.local_suites ?? []) {
    if (!declaredSuites.includes(suite)) {
      fail(`${file}: local suite "${suite}" is not one the file declares`);
    }
  }
}

if (offline) {
  console.error(
    'contract:check --offline: skipped the comparison against ' +
      `${pin.repo}@${refLabel}. Local digests only; run without --offline before merging.`,
  );
} else {
  // Upstream drift is independent of the local bookkeeping checks above, so it is reported even
  // when they failed — one red run should carry the whole story, not ration it across two.
  const fetched = await Promise.all(
    pinned.map(async file => {
      if (upstreamCache.has(file)) {
        return { file, upstream: upstreamCache.get(file).upstream };
      }
      try {
        return { file, upstream: await fetchUpstream(pin, file) };
      } catch (error) {
        return { file, error };
      }
    }),
  );
  for (const { file, upstream, error } of fetched) {
    if (error) {
      // Never downgrade an unreachable upstream to a pass: an unchecked copy is the whole failure
      // mode this script exists for.
      fail(
        `${file}: could not read the pinned copy (${error.message}). ` +
          'Use --offline only when the network is genuinely unavailable.',
      );
      continue;
    }
    const localPath = path.join(vectorDir, file);
    if (!fs.existsSync(localPath)) {
      continue; // already reported as "pinned but not vendored" above
    }
    if (!upstream.equals(fs.readFileSync(localPath))) {
      fail(
        `${file}: differs from ${pin.repo}@${refLabel}:${pin.source_dir}/${file}. ` +
          'Re-vendor with `npm run contract:sync`, or move the pin if upstream moved on purpose.',
      );
    } else {
      notes.push(`${file} matches ${pin.repo}@${refLabel}`);
    }
  }
}

for (const note of notes) {
  console.log(`ok  ${note}`);
}
if (failures.length > 0) {
  console.error('\ncontract vector check failed:');
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  process.exit(1);
}
console.log(`ok  ${pinned.length} contract vector files verified`);
