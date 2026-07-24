# Release checklist — license & corresponding-source obligations

The OpenRung mobile app statically links **sing-box / libbox**, which is
**GPL-3.0-or-later**. That makes the whole app GPL-3.0-or-later and imposes a
GPL §6 obligation: anyone you distribute a build to (TestFlight, Play, direct
APK) must be able to obtain the *complete corresponding source* for that exact
binary. This file is the per-release procedure that keeps that obligation
satisfiable. Do all of it before tagging a release.

## 1. Pin the sing-box revision

The sing-box engine revision is pinned in [`SINGBOX_VERSION`](SINGBOX_VERSION) as a Go
pseudo-version (`v0.0.0-<utc>-<12-char-commit>`; the trailing 12 characters are
the upstream commit SHA). Both build paths consume it:

- Android — [`android/build-libbox-release.sh`](android/build-libbox-release.sh)
  reads it directly.
- iOS — [`ios/ThirdParty/README.md`](ios/ThirdParty/README.md) checks out that
  commit before building `Libbox.xcframework`.

When you move to a newer sing-box, update `SINGBOX_VERSION` **only**, rebuild
both artifacts from it, and commit the new pin in the same change.

Android additionally compiles the first-party punch client into the same
gomobile AAR. It has two pins: the gomobile binding and its QUIC session layer
are committed under [`android/punchbridge`](android/punchbridge) and pinned by
the repository commit/tag being released, while the shared punch protocol core
is consumed as the Go module `github.com/openrung/openrung/punchcore` at the
version pinned in [`android/punchbridge/go.mod`](android/punchbridge/go.mod),
with `go.sum` recording its hash once the tagged version has been fetched.
Bumping the core is a `go.mod`/`go.sum` edit committed like a
`SINGBOX_VERSION` bump: rebuild the AAR in the same change.

Both native Libbox artifacts consume the WSS/CDN transport implementation only
as the tagged Go module `github.com/openrung/openrung/wsscore`, currently pinned
to **v0.2.0**
in `android/punchbridge/go.mod` with its checksum in `go.sum`. Do not copy its
WebSocket/TLS/yamux transport into this repository. A wsscore bump, like a
punchcore bump, MUST update the exact module pin and checksum and rebuild both
the combined Android AAR and unified Apple XCFramework in the same change.

Both artifacts also consume the broker control-plane implementation as the
tagged Go module `github.com/openrung/openrung/brokerapi`, pinned to **v0.1.0**
in the same `go.mod` with its checksum in `go.sum`. Its thin gomobile binding is
compiled into the existing libbox runtime; never create a second AAR or
XCFramework for it. Production constructors pass a nil HTTP client so eligible
direct connections to `broker.openrung.org:443` opportunistically try ECH and
retain brokerapi's verified ordinary-TLS fallback. The binding is native
foundation only until later changes migrate platform call sites.

### Bumping the punchcore pin

A punch wire/protocol change flows like this:

1. The change lands in the `openrung/openrung` repository (its hub, relays,
   and desktop client consume `punchcore/` via an in-repo `replace`, so the
   servers and desktop stay atomically consistent).
2. That PR bumps `punchcore/VERSION`; on merge, the openrung repo's
   `punchcore-tag.yml` workflow tags `punchcore/v$(VERSION)` on the merge
   commit automatically (a PR check there enforces the bump). If a tag is
   ever pushed by hand instead, push it **before** anything fetches the
   version: if `proxy.golang.org` was asked early, it negative-caches the
   miss — wait a few minutes for the cache TTL to expire and re-fetch.
3. Dependabot ([`.github/dependabot.yml`](.github/dependabot.yml), scoped to
   the three shared OpenRung modules only) opens the bump PR here — the require in
   `android/punchbridge/go.mod` plus `go.sum`. Manual fallback:
   `go get github.com/openrung/openrung/punchcore@vX.Y.Z` inside
   `android/punchbridge`. Either way the bump automatically busts the AAR CI
   caches (both cache keys hash `go.mod`/`go.sum`), and the bump PR itself
   rebuilds the AAR and runs the Android unit tests via
   `.github/workflows/android-unit-test.yml`.
4. Rebuild the AAR via `android/build-libbox-release.sh` and ship.

For local cross-repo development against an untagged punchcore checkout, use an
uncommitted `go.work` (see `.gitignore`) and/or
`PUNCHCORE_SRC=/path/to/openrung/punchcore android/build-libbox-release.sh`.
Both are **dev-only**: never commit a `replace`, and never release an AAR built
with `PUNCHCORE_SRC`, `WSSCORE_SRC`, or `BROKERAPI_SRC` set.

### Bumping the wsscore pin

Use only a released `wsscore/vX.Y.Z` tag from `openrung/openrung`; do not pin a
branch or pseudo-version. Dependabot is scoped to open bump PRs for all shared
OpenRung modules. Manual fallback, from `android/punchbridge`:

```sh
GOWORK=off go get github.com/openrung/openrung/wsscore@vX.Y.Z
```

For cross-repository development, set
`WSSCORE_SRC=/path/to/openrung/wsscore` when running
`android/build-libbox-release.sh` to supply an explicit local replace. It is
development-only: never commit that replace and never distribute an AAR built
with `WSSCORE_SRC` set.

### Bumping the brokerapi pin

Use only a released `brokerapi/vX.Y.Z` tag from `openrung/openrung`; never add a
committed local `replace`. Manual fallback, from `android/punchbridge`:

```sh
GOWORK=off go get github.com/openrung/openrung/brokerapi@vX.Y.Z
```

Rebuild and validate both Libbox artifacts in the same change. For coordinated
cross-repository development only, both build scripts accept
`BROKERAPI_SRC=/absolute/path/to/openrung/brokerapi`; artifacts built with that
override are not releasable.

## 2. Rebuild both engine artifacts from their corresponding source

Both are git-ignored (large, generated). Rebuild from the pinned revision:

```sh
# One-time Android build tools (the fork/version pinned by sing-box).
# The build script also needs python3 on PATH (parses all shared-module pins).
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12

# Android → android/app/libs/libbox.aar
#   (all four Android ABIs; bindings + pinned brokerapi/punchcore/wsscore)
./android/build-libbox-release.sh

# iOS → ios/ThirdParty/Libbox.xcframework
#   (device+simulator framework: sing-box + broker/WSS bindings and modules)
./ios/build-libbox-release.sh
```

The Android artifact inputs are the sing-box pin, the tagged
`android/punchbridge` source, and the brokerapi, punchcore, and wsscore module
versions in `android/punchbridge/go.mod`. The Apple artifact inputs are the
same sing-box pin, `broker_binding.go`, `wss_binding.go`, and the brokerapi and
wsscore pins. A stale cached AAR or XCFramework is a release blocker; release
CI must hash all inputs and the corresponding build script. For the shared
modules, CI hashes the *pins*
(`go.mod`/`go.sum`), not their
source trees — those live in the `openrung/openrung` repository at the recorded
versions, so the tagged versions, not the cache key, make the build reproducible.

Both build scripts trim sing-box's libbox build tags to the feature set OpenRung
actually uses before invoking sing-box's `build_libbox`: they drop
`with_tailscale` (and its `ts_omit_*` companions), `with_wireguard`, and
`with_naive_outbound`, none of which OpenRung ever emits (it uses only
vless/direct/block outbounds). `with_utls` (Reality), `with_clash_api` (byte
accounting), `with_gvisor`, and `with_quic` are kept. The trim is an
assert-then-replace patch of the tag literals in
`cmd/internal/build_libbox/main.go`, so a `SINGBOX_VERSION` bump that reshuffles
those literals fails the build and forces the tag set to be re-reviewed. The tag
set now materially defines the shipped binary, so it is part of the GPL
corresponding-source recipe and must stay recorded here.

The Android build targets all four ABIs at the **AAR** layer but ships an
**arm64-only release APK** — two artifacts, two distinct checks:

- **`libbox.aar` must still contain all four ABIs** (`armeabi-v7a`, `arm64-v8a`,
  `x86`, `x86_64`), matching `reactNativeArchitectures` in
  `android/gradle.properties`. Debug/emulator builds link this AAR, so an x86_64
  emulator needs its slice; inspect the AAR before release and reject a
  partial-ABI AAR (`unzip -l android/app/libs/libbox.aar | grep '\.so'` must list
  all four ABIs).
- **The signed release APK is intentionally arm64-only.** Broker telemetry showed
  ~0 genuinely 32-bit devices (every device is API ≥ 26 / Android 8.0+, all arm64),
  so armeabi-v7a is dropped along with the emulator-only x86/x86_64; this APK is a
  direct download, not a Play split delivery. It takes **two coordinated levers**,
  because non-arm64 `.so` reach the APK by two paths and `ndk.abiFilters` reliably
  controls neither:
  1. `android/app/build.gradle` applies a **release-scoped** `packaging.jniLibs`
     exclude (via `androidComponents`) that drops the armeabi-v7a/x86/x86_64 slices
     of the **AAR-prebuilt** libs (the libbox AAR, the MapLibre SDK).
  2. `.github/workflows/release.yml` builds with
     **`-PreactNativeArchitectures=arm64-v8a`**, so React Native's own prefab/Hermes
     cores (`libreactnative.so`, `libhermesvm.so`, `libjsi.so`, `libfbjni.so`,
     `libc++_shared.so`) never get non-arm64 slices. A manual `assembleRelease`
     **must pass this flag** or the RN cores ship other ABIs.

  Both are scoped to release, so debug keeps all four ABIs (any emulator still
  runs). It stays one monolithic universal APK, so offline sharing still accepts it
  (§4). **Verify** with `unzip -l app-release.apk | grep 'lib/'`: expect
  `lib/arm64-v8a/` entries only, and **no** `lib/armeabi-v7a/`, `lib/x86/`, or
  `lib/x86_64/`. (Measured: the tag trim + arm64-only took the release APK from
  ~360 MB to ~89 MB.)

  Should a genuinely 32-bit-only device ever appear (none in 8 days of telemetry;
  the app's telemetry has no ABI field, so this was inferred from OS level + model),
  restore `armeabi-v7a` to both levers.

There is currently **no CI gate that builds or inspects the Apple
XCFramework**. CI runs the Go binding tests and syntax-checks
`ios/build-libbox-release.sh`, but the device/simulator framework build still
requires macOS tooling and is a manual release gate. Until CI builds the
XCFramework, the release owner must run the script and verify both required
slices and exported WSS and broker symbols as described below.

For Android releases, also verify every live bare-IP punch coordinator's leaf
SHA-256 against `AppConfig.PUNCH_COORDINATOR_CERT_SHA256_BY_HOST`. Coordinate
certificate rotation by shipping the replacement pin before the broker starts
advertising the replacement endpoint/certificate.

## 3. WSS/CDN platform and rollout gate

The WSS/CDN client ships on Android and iOS, but every advertised relay must
retain its normal Reality endpoint for older client versions. Do not advertise
a WSS-only relay: direct Reality is always the first choice and remains the
compatibility and rollback path.

Roll out in this order:

1. Deploy and verify every CDN front and the broker ticket endpoint on all
   broker fronts. Tickets must be short-lived, single-use, and bound to the
   exact relay/front pair; redirects remain disabled.
2. Build `android/app/libs/libbox.aar` and
   `ios/ThirdParty/Libbox.xcframework` from their pinned inputs with the two
   release scripts. Confirm the AAR contains the WSS client, protector,
   listener, result, and front-validation symbols plus the broker operation
   constructors/results. Confirm both Apple device arm64 and simulator
   arm64/x86_64 slices export matching
   `LibboxNewOpenRungWSSClientForIOS`,
   `LibboxNewOpenRungBrokerOperationForIOS`, and broker result headers. A local
   `BROKERAPI_SRC`, `WSSCORE_SRC`, or `PUNCHCORE_SRC` artifact is a release
   blocker.
3. Run `go test -race ./...` and `go vet ./...` in `android/punchbridge`, the
   complete Android JVM and iOS unit suites, and Android/iOS platform builds.
   Smoke-test real devices on both platforms: direct success (no ticket),
   eligible remote failure (ticket then WSS), disconnect during dial, and
   Wi-Fi/cellular changes. For a signed native one-label `*.cloudfront.net`
   front, capture the ClientHello at a controlled edge and verify that SNI is
   absent while the encrypted HTTP Host remains the exact signed hostname and
   invalid certificates still fail. Also verify that custom CloudFront CNAMEs
   and other CDNs retain ordinary URL-derived SNI. Never retry the same
   single-use ticket with SNI after an ambiguous no-SNI handshake failure.
   Android additionally verifies
   protection refusal never connects; iOS verifies the PacketTunnel-only Apple constructor uses
   the nil-protector wsscore path, and that startup/health classification
   uses the bounded `createTCPConnectionThroughTunnel` probe rather than a
   provider-originated `URLSession`. A simulator build is necessary but is not
   a substitute for either real-device VPN test.
4. Add canonical, ID-sorted fronts to a small set of eligible foundation,
   direct, port-443 relay descriptors and sign the complete list. Never repair
   malformed signed input client-side. Expand only after ticket issuance,
   handshake, end-to-end probe, and network-recovery rates are healthy.
5. Watch `transport_fallback`, `transport_failed` (`transport=wss`, front ID,
   stage), `transport_path_lost`, and `connection_succeeded.transport`. Only the
   direct failure may affect relay health; ticket/CDN/front failures are
   transport-only signals. A rise in WSS failures must not quarantine the relay.
   Also verify a changed physical-network fingerprint on iOS, and a
   physical-network epoch change on Android, stop the Reality engine before the
   WSS adapter and recover through fresh signed discovery, direct-first, and
   fresh-ticket policy. Repeated identical `NWPath` callbacks and extension wake
   alone must leave a healthy iOS WSS session in place and must not mint a ticket;
   wake resumes the engine. A native WSS close or the configured end-to-end
   health-failure threshold must still start recovery. On Android, verify
   unexpected libbox exit is terminal on direct, punched, and WSS sessions: it
   must not reladder or request a ticket. WSS recovery must cancel the engine
   monitor, stop libbox, close the epoch monitor, and then close the WSS adapter
   before waiting for a usable physical network.

Rollback is descriptor-first: remove `wss_fronts` from newly signed relay lists
to return new sessions to direct-only behavior, while keeping the ticket API and
fronts alive long enough for already-issued short-lived tickets and active
sessions to drain. Do not reuse a ticket during rollback or after a physical
network change.

## 4. Verify the license surfaces are current

- **Bundled notices** — [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and
  its in-app mirror [`src/licenses/notices.ts`](src/licenses/notices.ts) must
  list every distributed dependency. If you added or removed a runtime native
  dependency this cycle, update **both** (they are kept in sync by hand) and
  bump versions.
- **In-app screen** — confirm the About tab → "Open-source licenses" screen
  and its full-text sub-screen render the notices and the full GPL-3.0 text.
- **Source link** — `AppConfig.SOURCE_URL` in
  [`src/config.ts`](src/config.ts) must point at this repository, and the
  repository must be reachable by whoever receives the build (GPL §6). If the
  repo is private, publish it or a mirror before external distribution.

### Android offline-sharing check

Install the signed `assembleRelease` artifact on an Android device and confirm
that Settings → General → "Share OpenRung offline" opens the system sharesheet
with an `OpenRung-<version>.apk` attachment.
`adb shell pm path com.openrung.mobile` must report exactly one APK path for the
release used in this test. The app intentionally refuses installs with
`splitSourceDirs`, because their `sourceDir` is only `base.apk` and cannot be
installed independently on the receiving phone. Complete one offline
phone-to-phone transfer and verify the received APK's SHA-256 and signing
certificate against the original release artifact before publishing.

## 5. Verify Apple privacy disclosures

Before every TestFlight or App Store submission, confirm the public policy at
`https://www.openrung.org/privacy` still matches the shipping iOS telemetry.
Then update and publish the App Privacy answers in App Store Connect. The
answers must match [`ios/OpenRung/PrivacyInfo.xcprivacy`](ios/OpenRung/PrivacyInfo.xcprivacy):

| App Store Connect data type | Current iOS beta data | Linked to user | Purposes |
| --- | --- | --- | --- |
| Coarse Location | IP-derived country and city | Yes | App Functionality; Analytics |
| Device ID | Persistent installation ID plus connection/session/event IDs linked to it | Yes | App Functionality; Analytics |
| Product Interaction | Connection attempts and outcomes, relay choice, manual speed tests | Yes | App Functionality; Analytics |
| Other Usage Data | Session/connection duration, heartbeats, and cumulative traffic totals | Yes | App Functionality; Analytics |
| Performance Data | Broker, relay, tunnel, probe, and speed-test timings | Yes | App Functionality; Analytics |
| Other Diagnostic Data | Failure details plus app, OS, device, and network diagnostics | Yes | App Functionality; Analytics |
| Other Data Types | Public/source IP, provider/organization/ASN, locale, time zone, and network state | Yes | App Functionality; Analytics |

All current types are **not used for tracking**. Also set the App Store Connect
Privacy Policy URL to `https://www.openrung.org/privacy`. If the telemetry
schema changes, update the manifest, this table, the public policy, and App
Store Connect together before distributing the new build.

## 6. App Store / DRM caveat (must be resolved separately)

Distributing a GPL-linked binary through the App Store (and likely external
TestFlight) conflicts with Apple's Usage Rules / DRM under GPL §6/§10. This is
**not** resolved by anything in this repo. Before any public Apple release,
either obtain a licensing exception from SagerNet for sing-box or move the
engine out-of-process. Google Play does not have the equivalent conflict.

## 7. Retention

OpenRung provides the corresponding source for at least **three (3) years**
after distribution. Keep the tagged commit (including `android/punchbridge`) +
the matching `SINGBOX_VERSION` + the pinned
`github.com/openrung/openrung/brokerapi` version (the
`brokerapi/vX.Y.Z` tag) +
the pinned
`github.com/openrung/openrung/punchcore` version (the `punchcore/vX.Y.Z` tag in
the `openrung/openrung` repository recorded in `android/punchbridge/go.mod`) +
the pinned `github.com/openrung/openrung/wsscore` version (`wsscore/vX.Y.Z`)
reachable for that long. This extends the 3-year retention promise to both
artifacts and all shared modules in the `openrung/openrung` repository's tagged
history.

## 8. Bumping the app version

The version **string** lives in exactly one place — `version` in
[`package.json`](package.json). Everything else derives from it, so never edit
the version in the other files by hand:

- **Android** `versionName` — read from `package.json` by
  [`android/app/build.gradle`](android/app/build.gradle) at build time.
- **iOS** `MARKETING_VERSION` — injected as `${APP_VERSION}` when
  [`ios/scripts/generate-project.sh`](ios/scripts/generate-project.sh)
  regenerates the Xcode project.
- **In-app** `APP_VERSION` — imported from `package.json` in
  [`src/config.ts`](src/config.ts).

To cut a new version:

```sh
npm version <new-version> --no-git-tag-version   # or edit package.json's "version"
./ios/scripts/generate-project.sh                # re-bake iOS MARKETING_VERSION
npm run version:check                            # verify everything is in sync
```

`npm run version:check` ([`scripts/check-versions.mjs`](scripts/check-versions.mjs))
is also run in CI ([`.github/workflows/version-check.yml`](.github/workflows/version-check.yml))
and fails the build if any source drifts from `package.json` — in practice the
only thing that can drift is a stale committed `project.pbxproj` (fix by
re-running `generate-project.sh`).

The Android `versionCode` and iOS `CURRENT_PROJECT_VERSION` are **build
numbers**, a separate monotonic integer from the version string; bump those by
hand per store upload.

## 9. Update manifest (in-app update check)

Every release automatically publishes a signed `update-manifest.json` (release
asset + R2 mirror) that shipped apps poll to learn about new versions, the
supported-version floor, and operator broadcasts. Per release, decide ONE
thing: does this release warrant a prompt? If yes, set `promote: "notify"` in
[`release/update-policy.json`](release/update-policy.json) in the version-bump
PR (and revert to `"silent"` in the next one); if it's a routine release,
touch nothing. After manually uploading an iOS build to TestFlight, bump
`ios_latest` in the same policy file — the manifest advertises exactly that
to iOS users, so it stays honest while the (manual) iOS pipeline lags Android. Raising `min_supported` (the kill switch) and broadcasting
notices are policy edits with their own workflow and do not require a release
at all — see [`release/README.md`](release/README.md) and
[`docs/UPDATE_MANIFEST.md`](docs/UPDATE_MANIFEST.md) (signing-key handling
lives there too: secret `OPENRUNG_MANIFEST_SIGNING_SEED_B64`).
