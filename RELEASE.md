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

Android additionally compiles the first-party punch client committed under
[`android/punchbridge`](android/punchbridge) into the same gomobile AAR. Its pin
is therefore the repository commit/tag being released, not a separate version.

## 2. Rebuild both engine artifacts from their corresponding source

Both are git-ignored (large, generated). Rebuild from the pinned revision:

```sh
# One-time Android build tools (the fork/version pinned by sing-box).
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12

# Android → android/app/libs/libbox.aar (sing-box + android/punchbridge)
./android/build-libbox-release.sh

# iOS → ios/ThirdParty/Libbox.xcframework
#   follow ios/ThirdParty/README.md (it checks out the pinned commit)
```

The sing-box pin **and the tagged `android/punchbridge` source** must match the
binary you ship. A stale cached AAR is a release blocker; release CI hashes both
native source inputs and the build script.

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

## 4. App Store / DRM caveat (must be resolved separately)

Distributing a GPL-linked binary through the App Store (and likely external
TestFlight) conflicts with Apple's Usage Rules / DRM under GPL §6/§10. This is
**not** resolved by anything in this repo. Before any public Apple release,
either obtain a licensing exception from SagerNet for sing-box or move the
engine out-of-process. Google Play does not have the equivalent conflict.

## 5. Retention

OpenRung provides the corresponding source for at least **three (3) years**
after distribution. Keep the tagged commit (including `android/punchbridge`) +
the matching `SINGBOX_VERSION` reachable for that long.

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
