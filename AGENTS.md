# OpenRung mobile — agent guide

## Public repository — censorship opsec

Treat this repository as public. **Document mechanisms, never circumvention
intelligence**, including in commit messages and PR titles/bodies:

- Reachability measurements, per-front results or latencies, vantage points and dates.
- Observed censor behaviour, explanations of why fronts survive, or health assessments.
- Probing methodology or plans for undeployed fronts.
- Known-unmitigated weaknesses, including abuse or rate-limit gaps.

Keep intelligence in the private operations notes (Obsidian vault). Publicly state
only the decision, without reasons or evidence. Before committing changes to broker
fronts, discovery order or blocking, review the diff and commit message as a censor would.


## Overview and code map

React Native/TypeScript UI over a shared Go `connectcore` VPN engine, hosted by
Android `VpnService` and iOS `NEPacketTunnelProvider` using sing-box/libbox.
The broker handles discovery; relays carry user traffic.

| Path | Owns |
| --- | --- |
| `App.tsx`, `src/screens/`, `src/components/` | Navigation and UI. |
| `src/state/`, `src/model/` | App state, native events and directory models. |
| `src/native/`, `src/net/` | Bridge contracts and app-side broker/update clients. |
| `src/i18n/`, `src/licenses/` | Translations and bundled license text. |
| `android/app/` | Kotlin VPN host, React Native bridges and Android integration. |
| `ios/PacketTunnel/`, `ios/Shared/` | Swift VPN extension and shared native code. |
| `android/punchbridge/` | Go bindings consumed by both platforms; pins shared OpenRung modules. |
| `testdata/`, `__tests__/` | Contract fixtures and JavaScript tests. |
| `scripts/`, `.github/workflows/` | Validation helpers and authoritative CI checks. |

## Design and changes

- Prefer the simplest design that meets requirements. Choose fewer abstractions,
  dependencies and moving parts when the result is equivalent. Reuse existing patterns;
  add complexity only for a concrete need.
- Keep connection policy in shared `connectcore` (the sibling `openrung` repo),
  OS integration in native hosts, and presentation in TypeScript.
- `OpenRungVpn` owns VPN lifecycle; `OpenRungBroker` handles eligible broker calls.
  Keep WSS tickets, credentials and front URLs native. Do not add a JavaScript broker
  fallback or a second Go runtime/AAR/XCFramework.
- [CONTRACT.md](docs/CONTRACT.md) takes precedence over the architecture overview.
  Preserve Android/iOS parity and bridge compatibility.
- Shared Go dependencies are pinned in `android/punchbridge/go.mod` and `go.sum`;
  sing-box is pinned in `SINGBOX_VERSION`. Rebuild both native artifacts after pin
  changes. Never commit local replacements or release with development overrides.
- `package.json` is the app-version source. Regenerate the iOS project using
  `ios/scripts/generate-project.sh` after version/project changes.
- Contract vectors are vendored from a pinned upstream ref. Use `contract:sync`
  for intentional updates; do not silently edit fixtures independently of upstream.
- Follow [RELEASE.md](RELEASE.md) for dependency notices, corresponding source and
  release requirements. Keep generated engine artifacts out of Git.

## Validation

Use Node from `package.json` (currently >=22.11), npm lockfiles, and Go from the
binding module. Run checks relevant to the changed layers:

| Run from | Checks |
| --- | --- |
| Root | `npm ci`; `npm run lint`; `npx tsc --noEmit`; `npm test -- --ci --runInBand` |
| Root, contracts/config | `npm run transport:check`; `npm run contract:check`; `npm run version:check` |
| `android/punchbridge/` | `go test -race ./...` |
| Root, engine bindings | `python3 scripts/test-engine-vectors.py -race` |
| `android/`, with native prerequisites | `./gradlew --no-daemon :app:testDebugUnitTest --stacktrace` |

`contract:check` needs network access. Native builds require generated libbox
artifacts and platform SDKs; follow the README and relevant CI workflow for setup.
JavaScript tests alone do not validate VPN behavior. Use the engine-binding docs
for native/device checks and report checks run, skips and missing prerequisites.

## User responses

Keep replies short and direct. Lead with results; include only relevant changes,
validation, limitations or required action. Skip internal deliberation, process
narration and repeated summaries.

## Further reading

[README](README.md): setup and builds;
[architecture](docs/ARCHITECTURE.md): ownership;
[engine binding](docs/ENGINE_BINDING.md): native integration;
[third-party iOS](ios/ThirdParty/README.md): engine artifacts;
[release tooling](release/README.md): distribution.
Keep this guide brief and update it when paths or workflows change.
