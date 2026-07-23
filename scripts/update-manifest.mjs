#!/usr/bin/env node
// Update-manifest tooling: generates (and optionally Ed25519-signs) the signed envelope the app's
// in-app update check consumes, validates the committed release/update-policy.json, and guards the
// committed test vectors in testdata/update_manifest_vectors.json.
//
// The manifest URL and schema are a FOREVER CONTRACT with every shipped client (see
// docs/UPDATE_MANIFEST.md): schema stays 1, changes are additive-only, and clients ignore fields
// they don't know. Do not "clean up" old fields.
//
// Uses only node:crypto (no node_modules) so it runs in workflows without `npm ci`.
//
// Modes:
//   node scripts/update-manifest.mjs generate --out update-manifest.json [--android-latest x.y.z]
//       Builds the envelope from package.json (version), android/app/build.gradle (versionCode)
//       and release/update-policy.json. Signs it when OPENRUNG_MANIFEST_SIGNING_SEED_B64 is set
//       (the base64 32-byte Ed25519 seed); otherwise emits an unsigned envelope with a warning —
//       unsigned manifests can never hard-block clients, only surface the passive update row.
//       --android-latest overrides the advertised Android version (the publisher workflow passes
//       the latest RELEASE tag so a still-building/failed release is never advertised); iOS
//       latest always comes from the policy file's ios_latest (TestFlight uploads are manual).
//       --release-published-at (the resolved release's published_at) folds the release input
//       into generated_at so equal stamps always mean identical manifests — see generatedAtIso.
//   node scripts/update-manifest.mjs check
//       CI guard: validates release/update-policy.json and the committed test vectors. Run by
//       .github/workflows/version-check.yml on every PR.
//   node scripts/update-manifest.mjs keygen [--name active]
//       Prints a fresh keypair as JSON: seed_b64 (SECRET — GitHub secret + password manager only,
//       never committed), public_key_hex + key_id (pin in src/config.ts MANIFEST_SIGNING_KEYS),
//       and the vector_message/vector_signature_b64 pair to commit to testdata pinned_keys so CI
//       can guard the pin without the seed.

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  randomBytes,
  sign as ed25519Sign,
  verify as ed25519Verify,
} from 'node:crypto';
import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, isAbsolute, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');

const POLICY_PATH = 'release/update-policy.json';
const VECTORS_PATH = 'testdata/update_manifest_vectors.json';
const SEED_ENV = 'OPENRUNG_MANIFEST_SIGNING_SEED_B64';

// --- Ed25519 over raw 32-byte seeds via node:crypto DER framing -------------------------------

const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function privateKeyFromSeed(seed) {
  if (seed.length !== 32) {
    throw new Error(`Ed25519 seed must be 32 bytes, got ${seed.length}`);
  }
  return createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: 'der', type: 'pkcs8' });
}

function publicKeyRawFromSeed(seed) {
  const spki = createPublicKey(privateKeyFromSeed(seed)).export({ format: 'der', type: 'spki' });
  return Buffer.from(spki.subarray(spki.length - 32));
}

function publicKeyFromRaw(raw) {
  return createPublicKey({ key: Buffer.concat([SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
}

/** key_id = lowercase hex of the first 8 bytes of SHA-256 over the raw public key (SPEC v1 §4.2). */
function keyIdOf(rawPublicKey) {
  return createHash('sha256').update(rawPublicKey).digest('hex').slice(0, 16);
}

function signBytes(seed, bytes) {
  return ed25519Sign(null, bytes, privateKeyFromSeed(seed));
}

function verifyBytes(rawPublicKey, bytes, signature) {
  try {
    return ed25519Verify(null, bytes, publicKeyFromRaw(rawPublicKey), signature);
  } catch {
    return false;
  }
}

// --- Shared validation ------------------------------------------------------------------------

const SEMVER_RE = /^\d+\.\d+\.\d+$/;

function semverTriple(value) {
  return SEMVER_RE.test(value) ? value.split('.').map(Number) : null;
}

function semverLte(a, b) {
  const ta = semverTriple(a);
  const tb = semverTriple(b);
  if (!ta || !tb) {
    return false;
  }
  for (let i = 0; i < 3; i++) {
    if (ta[i] !== tb[i]) {
      return ta[i] < tb[i];
    }
  }
  return true;
}

function isLocalizedMap(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const entries = Object.entries(value);
  return (
    typeof value.en === 'string' &&
    value.en.trim().length > 0 &&
    entries.every(([, text]) => typeof text === 'string' && text.trim().length > 0)
  );
}

/** Validates release/update-policy.json; returns a list of human-readable problems. */
function validatePolicy(policy, currentVersion) {
  const errors = [];
  if (policy.schema !== 1) {
    errors.push(`policy schema must be 1, got ${JSON.stringify(policy.schema)}`);
  }
  for (const platform of ['android', 'ios']) {
    const min = policy.min_supported?.[platform];
    if (typeof min !== 'string' || !SEMVER_RE.test(min)) {
      errors.push(`min_supported.${platform} must be "x.y.z", got ${JSON.stringify(min)}`);
    } else if (!semverLte(min, currentVersion)) {
      // A floor above the version being released would block even fully-updated users.
      errors.push(
        `min_supported.${platform} (${min}) is above the current app version (${currentVersion})`,
      );
    }
  }
  // iOS releases are manual (TestFlight), so nothing in CI knows what is actually live; the
  // operator records it here and the manifest advertises exactly that — never an unbuilt version.
  const iosLatest = policy.ios_latest;
  if (typeof iosLatest !== 'string' || !SEMVER_RE.test(iosLatest)) {
    errors.push(
      `ios_latest must be "x.y.z" (the version actually live on TestFlight), got ${JSON.stringify(iosLatest)}`,
    );
  } else {
    if (!semverLte(iosLatest, currentVersion)) {
      errors.push(
        `ios_latest (${iosLatest}) is above the current app version (${currentVersion}) — cannot advertise an unbuilt iOS release`,
      );
    }
    const minIos = policy.min_supported?.ios;
    if (typeof minIos === 'string' && SEMVER_RE.test(minIos) && !semverLte(minIos, iosLatest)) {
      errors.push(
        `min_supported.ios (${minIos}) is above ios_latest (${iosLatest}) — would block users with no available fix`,
      );
    }
  }
  if (policy.promote !== 'silent' && policy.promote !== 'notify') {
    errors.push(`promote must be "silent" or "notify", got ${JSON.stringify(policy.promote)}`);
  }
  const notice = policy.notice;
  if (notice !== null && notice !== undefined) {
    if (typeof notice !== 'object' || Array.isArray(notice)) {
      errors.push('notice must be null or an object');
    } else {
      if (typeof notice.id !== 'string' || notice.id.trim().length === 0 || notice.id.length > 64) {
        errors.push('notice.id must be a non-empty string (max 64 chars)');
      }
      if (notice.level !== 'info' && notice.level !== 'warn') {
        errors.push(`notice.level must be "info" or "warn", got ${JSON.stringify(notice.level)}`);
      }
      if (!isLocalizedMap(notice.title)) {
        errors.push('notice.title must be a {locale: text} map with a non-empty "en" entry');
      }
      if (!isLocalizedMap(notice.body)) {
        errors.push('notice.body must be a {locale: text} map with a non-empty "en" entry');
      }
      if (notice.url != null && !/^https:\/\//.test(notice.url)) {
        errors.push('notice.url must be null or an https:// URL');
      }
      if (notice.expires != null && Number.isNaN(Date.parse(notice.expires))) {
        errors.push(`notice.expires must be null or ISO-8601, got ${JSON.stringify(notice.expires)}`);
      }
    }
  }
  return errors;
}

// --- Inputs -----------------------------------------------------------------------------------

function currentAppVersion() {
  return JSON.parse(read('package.json')).version;
}

function currentVersionCode() {
  const match = read('android/app/build.gradle').match(/versionCode\s+(\d+)/);
  if (!match) {
    throw new Error('android/app/build.gradle: versionCode not found');
  }
  return Number(match[1]);
}

function loadPolicy() {
  return JSON.parse(read(POLICY_PATH));
}

function loadVectors() {
  return JSON.parse(read(VECTORS_PATH));
}

/**
 * generated_at = the NEWEST timestamp among ALL manifest inputs — the generating checkout's HEAD
 * committer time and (when the workflow passes it) the resolved latest release's published_at.
 * Never plain wall-clock: the inputs' own history is the ordering authority, so a stale-input
 * publish that lands late carries an honestly-older stamp and cached clients reject the
 * rollback. Because BOTH inputs are monotone (new commits and new releases only move forward),
 * any input change strictly increases the stamp — which gives clients the invariant that EQUAL
 * generated_at implies an identical manifest (same policy commit, same release), so they can
 * safely stop walking / keep their cache on ties. A wall-clock stamp would break the rollback
 * direction; a commit-time-only stamp would break the tie invariant (same commit, new release).
 */
function generatedAtIso(releasePublishedAtIso) {
  let headIso;
  try {
    headIso = execSync('git log -1 --format=%cI', { cwd: root, encoding: 'utf8' }).trim();
    if (Number.isNaN(Date.parse(headIso))) {
      throw new Error(`unparseable committer date ${JSON.stringify(headIso)}`);
    }
  } catch (error) {
    console.warn(
      `⚠ could not read the HEAD committer time (${error.message ?? error}) — ` +
        'falling back to wall-clock generated_at (rollback ordering is weaker for this manifest).',
    );
    headIso = new Date().toISOString();
  }
  if (releasePublishedAtIso == null) {
    return headIso;
  }
  if (Number.isNaN(Date.parse(releasePublishedAtIso))) {
    console.error(
      `✖ --release-published-at must be ISO-8601, got ${JSON.stringify(releasePublishedAtIso)}`,
    );
    process.exit(1);
  }
  return Date.parse(releasePublishedAtIso) > Date.parse(headIso) ? releasePublishedAtIso : headIso;
}

// --- generate ---------------------------------------------------------------------------------

function buildPayload(version, versionCode, policy, androidLatest, generatedAt) {
  return {
    schema: 1,
    generated_at: generatedAt,
    android: {
      latest: androidLatest,
      // versionCode is read from the working tree, which only describes the advertised build
      // when the advertised version IS the working-tree version (release path). In broadcast
      // mode (androidLatest from the release tag) the code is unknowable here; null it rather
      // than lie. Informational only — clients ignore it.
      latest_code: androidLatest === version ? versionCode : null,
      min_supported: policy.min_supported.android,
    },
    ios: {
      // Manual TestFlight pipeline: advertise what the operator recorded as actually live,
      // never the source version (which may not be built for iOS yet).
      latest: policy.ios_latest,
      min_supported: policy.min_supported.ios,
    },
    promote: policy.promote,
    notice: policy.notice ?? null,
  };
}

function generate(outPath, androidLatestOverride, releasePublishedAt) {
  const version = currentAppVersion();
  const policy = loadPolicy();
  const policyErrors = validatePolicy(policy, version);
  if (policyErrors.length) {
    console.error(`✖ ${POLICY_PATH} is invalid:`);
    for (const e of policyErrors) console.error(`  - ${e}`);
    process.exit(1);
  }

  // Android latest: the release path (no override) advertises the working-tree version — the
  // manifest is attached to the same GitHub release as that APK, so they publish atomically.
  // The broadcast workflow passes --android-latest <latest release tag> so a version bump on
  // main whose release is still building (or failed) is never advertised before it exists.
  if (androidLatestOverride != null && !SEMVER_RE.test(androidLatestOverride)) {
    console.error(`✖ --android-latest must be "x.y.z", got ${JSON.stringify(androidLatestOverride)}`);
    process.exit(1);
  }
  const androidLatest = androidLatestOverride ?? version;
  if (!semverLte(policy.min_supported.android, androidLatest)) {
    console.error(
      `✖ min_supported.android (${policy.min_supported.android}) is above the published android ` +
        `latest (${androidLatest}) — would block users with no available fix. Wait for the ` +
        `release of the new version to finish, then re-run.`,
    );
    process.exit(1);
  }

  const payload = buildPayload(
    version,
    currentVersionCode(),
    policy,
    androidLatest,
    generatedAtIso(releasePublishedAt),
  );
  const payloadBytes = Buffer.from(JSON.stringify(payload), 'utf8');
  const envelope = { schema: 1, payload_b64: payloadBytes.toString('base64') };

  const seedB64 = process.env[SEED_ENV] ?? '';
  if (seedB64.trim().length > 0) {
    const seed = Buffer.from(seedB64.trim(), 'base64');
    const rawPublic = publicKeyRawFromSeed(seed);
    const keyId = keyIdOf(rawPublic);
    // Refuse to sign with a key clients don't pin: a manifest signed by an unpinned key verifies
    // nowhere and silently downgrades every client to the unsigned (never-blocking) tier.
    const pinned = loadVectors().pinned_keys.some(
      (key) => key.public_key_hex === rawPublic.toString('hex'),
    );
    if (!pinned) {
      console.error(
        `✖ ${SEED_ENV} derives public key ${rawPublic.toString('hex')} (key_id ${keyId}), ` +
          `which is not in ${VECTORS_PATH} pinned_keys. Pin it (and src/config.ts) first.`,
      );
      process.exit(1);
    }
    const signature = signBytes(seed, payloadBytes);
    envelope.sig = `ed25519;${keyId};${signature.toString('base64')}`;
    // Round-trip self-check so a bad signer can never ship a broken envelope.
    if (!verifyBytes(rawPublic, payloadBytes, signature)) {
      console.error('✖ self-verification of the freshly signed envelope failed');
      process.exit(1);
    }
    console.log(`✓ signed with key_id ${keyId}`);
  } else {
    console.warn(
      `⚠ ${SEED_ENV} not set — emitting an UNSIGNED envelope. ` +
        'Clients will show the passive update row only; they never hard-block on unsigned manifests.',
    );
  }

  writeFileSync(isAbsolute(outPath) ? outPath : join(root, outPath), JSON.stringify(envelope, null, 2) + '\n');
  console.log(`✓ wrote ${outPath} (version ${version}, promote ${policy.promote})`);
}

// --- check ------------------------------------------------------------------------------------

function check() {
  const errors = [];
  const version = currentAppVersion();

  let policy = null;
  try {
    policy = loadPolicy();
  } catch (error) {
    errors.push(`${POLICY_PATH}: ${error.message}`);
  }
  if (policy) {
    errors.push(...validatePolicy(policy, version).map((e) => `${POLICY_PATH}: ${e}`));
  }

  let vectors = null;
  try {
    vectors = loadVectors();
  } catch (error) {
    errors.push(`${VECTORS_PATH}: ${error.message}`);
  }
  if (vectors) {
    // Test key self-consistency: pubkey/key_id derive from the committed TEST seed.
    const testSeed = Buffer.from(vectors.test_key.seed_b64, 'base64');
    const testRaw = publicKeyRawFromSeed(testSeed);
    if (testRaw.toString('hex') !== vectors.test_key.public_key_hex) {
      errors.push(`${VECTORS_PATH}: test_key.public_key_hex does not derive from seed_b64`);
    }
    if (keyIdOf(testRaw) !== vectors.test_key.key_id) {
      errors.push(`${VECTORS_PATH}: test_key.key_id does not derive from public key`);
    }

    // Vector envelope: payload_b64 matches payload_json byte-for-byte, sig verifies with test key.
    const vector = vectors.vector;
    const payloadBytes = Buffer.from(vector.payload_b64, 'base64');
    if (payloadBytes.toString('utf8') !== vector.payload_json) {
      errors.push(`${VECTORS_PATH}: vector.payload_b64 does not decode to vector.payload_json`);
    }
    const sigFields = vector.sig.split(';');
    if (sigFields.length !== 3 || sigFields[0] !== 'ed25519' || sigFields[1] !== vectors.test_key.key_id) {
      errors.push(`${VECTORS_PATH}: vector.sig is not "ed25519;<test key_id>;<base64>"`);
    } else if (!verifyBytes(testRaw, payloadBytes, Buffer.from(sigFields[2], 'base64'))) {
      errors.push(`${VECTORS_PATH}: vector.sig does not verify against test_key`);
    }
    const envelope = JSON.parse(vector.envelope_json);
    if (envelope.schema !== 1 || envelope.payload_b64 !== vector.payload_b64 || envelope.sig !== vector.sig) {
      errors.push(`${VECTORS_PATH}: vector.envelope_json disagrees with payload_b64/sig`);
    }

    // Pinned production keys: key_id derives, and the committed vector signature verifies — so a
    // truncated or typo'd pin fails CI immediately, without the offline seed (same guard idea as
    // the relay-list pinned-key CI guard).
    for (const key of vectors.pinned_keys) {
      const raw = Buffer.from(key.public_key_hex, 'hex');
      if (raw.length !== 32) {
        errors.push(`${VECTORS_PATH}: pinned key "${key.name}" public_key_hex is not 32 bytes`);
        continue;
      }
      if (keyIdOf(raw) !== key.key_id) {
        errors.push(`${VECTORS_PATH}: pinned key "${key.name}" key_id does not derive from public key`);
      }
      const message = Buffer.from(key.vector_message, 'utf8');
      const signature = Buffer.from(key.vector_signature_b64, 'base64');
      if (!verifyBytes(raw, message, signature)) {
        errors.push(`${VECTORS_PATH}: pinned key "${key.name}" vector signature does not verify`);
      }
    }
  }

  if (errors.length) {
    console.error('✖ update-manifest check failed:');
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  console.log(`✓ ${POLICY_PATH} and ${VECTORS_PATH} are valid (app version ${version}).`);
}

// --- keygen -----------------------------------------------------------------------------------

function keygen(name) {
  const seed = randomBytes(32);
  const raw = publicKeyRawFromSeed(seed);
  const message = `openrung-manifest-key-vector:${name}`;
  console.log(
    JSON.stringify(
      {
        seed_b64: seed.toString('base64'),
        public_key_hex: raw.toString('hex'),
        key_id: keyIdOf(raw),
        vector_message: message,
        vector_signature_b64: signBytes(seed, Buffer.from(message, 'utf8')).toString('base64'),
      },
      null,
      2,
    ),
  );
}

// --- CLI --------------------------------------------------------------------------------------

const [mode, ...rest] = process.argv.slice(2);
const flag = (label, fallback) => {
  const index = rest.indexOf(label);
  return index >= 0 && rest[index + 1] ? rest[index + 1] : fallback;
};

switch (mode) {
  case 'generate':
    generate(
      flag('--out', 'update-manifest.json'),
      flag('--android-latest', null),
      flag('--release-published-at', null),
    );
    break;
  case 'check':
    check();
    break;
  case 'keygen':
    keygen(flag('--name', 'active'));
    break;
  default:
    console.error(
      'usage: update-manifest.mjs <generate [--out file] [--android-latest x.y.z] | check | keygen [--name n]>',
    );
    process.exit(1);
}
