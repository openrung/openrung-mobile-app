# Release checklist — license & corresponding-source obligations

The OpenRung mobile app statically links **sing-box / libbox**, which is
**GPL-3.0-or-later**. That makes the whole app GPL-3.0-or-later and imposes a
GPL §6 obligation: anyone you distribute a build to (TestFlight, Play, direct
APK) must be able to obtain the *complete corresponding source* for that exact
binary. This file is the per-release procedure that keeps that obligation
satisfiable. Do all of it before tagging a release.

## 1. Pin the sing-box revision

The engine revision is pinned in [`SINGBOX_VERSION`](SINGBOX_VERSION) as a Go
pseudo-version (`v0.0.0-<utc>-<12-char-commit>`; the trailing 12 characters are
the upstream commit SHA). Both build paths consume it:

- Android — [`android/build-libbox-release.sh`](android/build-libbox-release.sh)
  reads it directly.
- iOS — [`ios/ThirdParty/README.md`](ios/ThirdParty/README.md) checks out that
  commit before building `Libbox.xcframework`.

When you move to a newer sing-box, update `SINGBOX_VERSION` **only**, rebuild
both artifacts from it, and commit the new pin in the same change.

## 2. Rebuild both engine artifacts from the pin

Both are git-ignored (large, generated). Rebuild from the pinned revision:

```sh
# Android → android/app/libs/libbox.aar
./android/build-libbox-release.sh

# iOS → ios/ThirdParty/Libbox.xcframework
#   follow ios/ThirdParty/README.md (it checks out the pinned commit)
```

The pin **must** match the binary you ship. If you build the engine from a
different commit than `SINGBOX_VERSION` records, the corresponding source is
wrong — treat that as a release blocker.

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
after distribution. Keep the tagged commit + the matching `SINGBOX_VERSION`
reachable for that long.
