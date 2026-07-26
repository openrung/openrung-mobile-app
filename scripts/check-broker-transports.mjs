#!/usr/bin/env node

/**
 * Regression guard for the mobile broker transport boundary.
 *
 * This intentionally scans only production call sites. Broker configuration, documentation,
 * tests, and the Go brokerapi implementation are out of scope. Ordinary HTTP implementations
 * are restricted to a small, reviewed allowlist; the one JavaScript exception is GitHub's exact
 * redirecting update-manifest asset.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8');
}

function walk(relativeDirectory, extensions) {
  const absoluteDirectory = path.join(root, relativeDirectory);
  const found = [];
  for (const entry of fs.readdirSync(absoluteDirectory, { withFileTypes: true })) {
    const relativePath = path.posix.join(relativeDirectory, entry.name);
    if (entry.isDirectory()) {
      found.push(...walk(relativePath, extensions));
    } else if (extensions.some(extension => entry.name.endsWith(extension))) {
      found.push(relativePath);
    }
  }
  return found;
}

// Remove comments without touching quoted URLs. This keeps policy checks focused on executable
// source and avoids rejecting architecture notes that explain an intentionally forbidden API.
function stripComments(source) {
  let output = '';
  let state = 'code';
  let escaped = false;
  for (let index = 0; index < source.length; index++) {
    const current = source[index];
    const next = source[index + 1];

    if (state === 'line-comment') {
      if (current === '\n') {
        state = 'code';
        output += '\n';
      } else {
        output += ' ';
      }
      continue;
    }
    if (state === 'block-comment') {
      if (current === '*' && next === '/') {
        output += '  ';
        index++;
        state = 'code';
      } else {
        output += current === '\n' ? '\n' : ' ';
      }
      continue;
    }
    if (state !== 'code') {
      output += current;
      if (escaped) {
        escaped = false;
      } else if (current === '\\') {
        escaped = true;
      } else if (
        (state === 'single-quote' && current === "'") ||
        (state === 'double-quote' && current === '"') ||
        (state === 'template' && current === '`')
      ) {
        state = 'code';
      }
      continue;
    }

    if (current === '/' && next === '/') {
      output += '  ';
      index++;
      state = 'line-comment';
    } else if (current === '/' && next === '*') {
      output += '  ';
      index++;
      state = 'block-comment';
    } else {
      output += current;
      if (current === "'") state = 'single-quote';
      if (current === '"') state = 'double-quote';
      if (current === '`') state = 'template';
    }
  }
  return output;
}

function countMatches(source, pattern) {
  return Array.from(source.matchAll(pattern)).length;
}

function requirePolicy(condition, message) {
  if (!condition) failures.push(message);
}

const brokerSensitiveFiles = [
  'src/net/brokerClient.ts',
  'src/net/speedTestClient.ts',
  'src/net/telemetryClient.ts',
];
for (const relativePath of brokerSensitiveFiles) {
  const source = stripComments(read(relativePath));
  requirePolicy(
    countMatches(source, /\bfetch\s*\(/g) === 0,
    `${relativePath}: broker transport must not call JavaScript fetch`,
  );
}

function javascriptFetchReferences(relativePath) {
  const source = read(relativePath);
  const scriptKind = relativePath.endsWith('.tsx')
    ? ts.ScriptKind.TSX
    : relativePath.endsWith('.jsx')
      ? ts.ScriptKind.JSX
      : relativePath.endsWith('.js')
        ? ts.ScriptKind.JS
        : ts.ScriptKind.TS;
  const sourceFile = ts.createSourceFile(
    relativePath,
    source,
    ts.ScriptTarget.Latest,
    true,
    scriptKind,
  );
  const references = [];

  function visit(node) {
    const isFetchIdentifier = ts.isIdentifier(node) && node.text === 'fetch';
    const isComputedFetch =
      ts.isElementAccessExpression(node) &&
      ts.isStringLiteralLike(node.argumentExpression) &&
      node.argumentExpression.text === 'fetch';
    if (isFetchIdentifier || isComputedFetch) {
      const position = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
      references.push({
        line: position.line + 1,
        directGitHubCall:
          isFetchIdentifier &&
          ts.isCallExpression(node.parent) &&
          node.parent.expression === node &&
          node.parent.arguments.length >= 1 &&
          ts.isIdentifier(node.parent.arguments[0]) &&
          node.parent.arguments[0].text === 'GITHUB_MANIFEST_URL',
      });
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return references;
}

const jsFiles = walk('src', ['.ts', '.tsx', '.js', '.jsx']);
const jsFetchSites = jsFiles.flatMap(relativePath => {
  const references = javascriptFetchReferences(relativePath);
  return references.length === 0 ? [] : [{ relativePath, references }];
});
requirePolicy(
  jsFetchSites.length === 1 &&
    jsFetchSites[0].relativePath === 'src/net/updateManifestClient.ts' &&
    jsFetchSites[0].references.length === 1 &&
    jsFetchSites[0].references[0].directGitHubCall,
  `src: expected exactly one direct fetch(GITHUB_MANIFEST_URL, ...) reference in updateManifestClient.ts; found ${JSON.stringify(
    jsFetchSites,
  )}`,
);

const manifestClient = stripComments(read('src/net/updateManifestClient.ts'));
const githubManifest =
  'https://github.com/openrung/openrung-mobile-app/releases/latest/download/update-manifest.json';
requirePolicy(
  manifestClient.includes(`const GITHUB_MANIFEST_URL =\n  '${githubManifest}'`) ||
    manifestClient.includes(`const GITHUB_MANIFEST_URL = '${githubManifest}'`),
  'updateManifestClient.ts: GitHub fallback must stay pinned to the exact release asset URL',
);
requirePolicy(
  /\bfetch\s*\(\s*GITHUB_MANIFEST_URL\s*,/.test(manifestClient),
  'updateManifestClient.ts: the sole JS fetch must receive GITHUB_MANIFEST_URL directly',
);
requirePolicy(
  manifestClient.includes(
    "const DIRECT_MANIFEST_URL = 'https://broker.openrung.org/api/v1/app-manifest'",
  ) &&
    manifestClient.includes(
      "'https://d2r7mdpyevvs1m.cloudfront.net/api/v1/app-manifest'",
    ) &&
    /\bnativeFetchManifestCandidate\s*\(\s*\{\s*candidateUrl:\s*url\s*\}/s.test(
      manifestClient,
    ),
  'updateManifestClient.ts: direct broker and CloudFront candidates must use the native candidate API',
);
requirePolicy(
  /\bnativeFirstReachable\s*\(/.test(stripComments(read('src/net/brokerClient.ts'))),
  'brokerClient.ts: directory selection must call native firstReachable',
);
requirePolicy(
  /\bnativeRunSpeedTest\s*\(/.test(stripComments(read('src/net/speedTestClient.ts'))),
  'speedTestClient.ts: speed tests must call native runSpeedTest',
);
requirePolicy(
  /\bsendTelemetryBatchJSON\s*\(/.test(
    stripComments(read('src/net/telemetryClient.ts')),
  ),
  'telemetryClient.ts: telemetry must call native sendTelemetryBatchJSON',
);

const forbiddenBrokerReferences =
  /broker\.openrung\.org|d2r7mdpyevvs1m\.cloudfront\.net|\/api\/v1\/(?:relays|telemetry|speed|app-manifest|wss-ticket)|DEFAULT_BROKER|brokerUrl|BrokerEndpoint|OpenRungDefaultBroker/i;

const androidHttpAllowlist = new Set([
  'android/app/src/main/java/com/openrung/net/GeoIpClient.kt',
  'android/app/src/main/java/com/openrung/net/InternetProbe.kt',
  'android/app/src/main/java/com/openrung/vpn/PhysicalNetworkProbe.kt',
]);
const androidFiles = walk('android/app/src/main/java', ['.kt', '.java']);
const androidHttpSites = androidFiles.filter(relativePath =>
  /\bHttpURLConnection\b/.test(stripComments(read(relativePath))),
);
for (const relativePath of androidHttpSites) {
  requirePolicy(
    androidHttpAllowlist.has(relativePath),
    `${relativePath}: HttpURLConnection is not an approved ordinary-HTTP call site`,
  );
}
for (const relativePath of androidHttpAllowlist) {
  const source = stripComments(read(relativePath));
  requirePolicy(
    /\bHttpURLConnection\b/.test(source),
    `${relativePath}: stale HttpURLConnection allowlist entry`,
  );
  requirePolicy(
    !forbiddenBrokerReferences.test(source),
    `${relativePath}: approved ordinary-HTTP code must not reference a broker endpoint`,
  );
}

const physicalProbePath =
  'android/app/src/main/java/com/openrung/vpn/PhysicalNetworkProbe.kt';
const physicalProbe = stripComments(read(physicalProbePath));
const physicalUrls = Array.from(
  physicalProbe.matchAll(/"(https:\/\/[^"]+)"/g),
  match => match[1],
).sort();
requirePolicy(
  JSON.stringify(physicalUrls) ===
    JSON.stringify(
      [
        'https://cp.cloudflare.com/generate_204',
        'https://www.gstatic.com/generate_204',
      ].sort(),
    ),
  `${physicalProbePath}: endpoint list must be exactly gstatic and Cloudflare generate_204`,
);
requirePolicy(
  /network\.openConnection\s*\(/.test(physicalProbe) &&
    /connectTimeout\s*=/.test(physicalProbe) &&
    /readTimeout\s*=/.test(physicalProbe) &&
    /instanceFollowRedirects\s*=\s*false/.test(physicalProbe) &&
    /useCaches\s*=\s*false/.test(physicalProbe) &&
    !/setRequestProperty\s*\(/.test(physicalProbe),
  `${physicalProbePath}: preserve physical-network routing, short timeouts, disabled redirects/caches, and no headers`,
);

const vpnServicePath =
  'android/app/src/main/java/com/openrung/vpn/OpenRungVpnService.kt';
const vpnService = stripComments(read(vpnServicePath));
const physicalMethod =
  vpnService.match(
    /private suspend fun physicalNetworkAlive\(\): Boolean\s*\{([\s\S]*?)\n\s*private suspend fun awaitPhysicalNetworkAlive/,
  )?.[1] ?? '';
requirePolicy(
  physicalMethod.includes('PhysicalNetworkProbe.ENDPOINTS') &&
    physicalMethod.includes('PhysicalNetworkProbe.isReachable') &&
    !/\bHttpURLConnection\b/.test(vpnService) &&
    !/physicalProbeBrokerFronts|broker|AppConfig|DEFAULT_BROKER/i.test(physicalMethod),
  `${vpnServicePath}: physicalNetworkAlive must use only PhysicalNetworkProbe endpoints`,
);

const iosUrlSessionAllowlist = new Set([
  'ios/Shared/GeoIpClient.swift',
  'ios/Shared/InternetProbe.swift',
]);
const iosFiles = ['ios/OpenRung', 'ios/PacketTunnel', 'ios/Shared'].flatMap(directory =>
  walk(directory, ['.swift', '.m', '.mm']),
);
const iosUrlSessionSites = iosFiles.filter(relativePath =>
  /\bURLSession(?:Task|DataTask|DownloadTask|Delegate|TaskDelegate|TaskMetrics)?\b/.test(
    stripComments(read(relativePath)),
  ),
);
for (const relativePath of iosUrlSessionSites) {
  requirePolicy(
    iosUrlSessionAllowlist.has(relativePath),
    `${relativePath}: URLSession is not an approved ordinary-HTTP call site`,
  );
}
for (const relativePath of iosUrlSessionAllowlist) {
  const source = stripComments(read(relativePath));
  requirePolicy(
    /\bURLSession\b/.test(source),
    `${relativePath}: stale URLSession allowlist entry`,
  );
  requirePolicy(
    !forbiddenBrokerReferences.test(source),
    `${relativePath}: approved ordinary-HTTP code must not reference a broker endpoint`,
  );
}

if (failures.length > 0) {
  console.error('Broker transport regression guard failed:\n');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log('Broker transport regression guard passed.');
