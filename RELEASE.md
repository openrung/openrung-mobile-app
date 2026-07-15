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
   the punchcore module only) opens the bump PR here — the require in
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
with `PUNCHCORE_SRC` set.

## 2. Rebuild both engine artifacts from their corresponding source

Both are git-ignored (large, generated). Rebuild from the pinned revision:

```sh
# One-time Android build tools (the fork/version pinned by sing-box).
# The build script also needs python3 on PATH (parses the punchcore pin).
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12

# Android → android/app/libs/libbox.aar
#   (sing-box + android/punchbridge binding + pinned punchcore module)
./android/build-libbox-release.sh

# iOS → ios/ThirdParty/Libbox.xcframework
#   follow ios/ThirdParty/README.md (it checks out the pinned commit)
```

The sing-box pin, **the tagged `android/punchbridge` source**, and the punchcore
module version pinned in `android/punchbridge/go.mod` must match the binary you
ship — three native source inputs, not two. A stale cached AAR is a release
blocker; release CI hashes all native source inputs and the build script. Note
that for the punch core CI hashes the *pin* (`go.mod`/`go.sum`), not the source
itself — the source lives in the `openrung/openrung` repository at that version,
so the pinned version, not the hash key, is what makes the build reproducible.

For Android releases, also verify every live bare-IP punch coordinator's leaf
SHA-256 against `AppConfig.PUNCH_COORDINATOR_CERT_SHA256_BY_HOST`. Coordinate
certificate rotation by shipping the replacement pin before the broker starts
advertising the replacement endpoint/certificate.

## 3. Verify the license surfaces are current

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

## 4. App Store / DRM caveat (must be resolved separately)

Distributing a GPL-linked binary through the App Store (and likely external
TestFlight) conflicts with Apple's Usage Rules / DRM under GPL §6/§10. This is
**not** resolved by anything in this repo. Before any public Apple release,
either obtain a licensing exception from SagerNet for sing-box or move the
engine out-of-process. Google Play does not have the equivalent conflict.

## 5. Retention

OpenRung provides the corresponding source for at least **three (3) years**
after distribution. Keep the tagged commit (including `android/punchbridge`) +
the matching `SINGBOX_VERSION` + the pinned
`github.com/openrung/openrung/punchcore` version (the `punchcore/vX.Y.Z` tag in
the `openrung/openrung` repository recorded in `android/punchbridge/go.mod`)
reachable for that long. This extends the 3-year retention promise to the
`openrung/openrung` repository's tagged history.

## 6. Bumping the app version

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
