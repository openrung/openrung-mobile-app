# Third-party iOS engine artifacts

> **License / GPL corresponding source.** sing-box is **GPL-3.0-or-later** and
> `Libbox.xcframework` is statically linked into the app and the PacketTunnel
> extension, so the whole iOS app is GPL-3.0-or-later (see the repo `LICENSE`
> and `THIRD_PARTY_NOTICES.md`). The build below pins the **exact sing-box
> revision** recorded in [`../../SINGBOX_VERSION`](../../SINGBOX_VERSION) so the
> GPL §6 corresponding source is reproducible — keep that pin in lockstep with
> the shipped binary (see [`../../RELEASE.md`](../../RELEASE.md)).
>
> **App Store caveat:** distributing this GPL-linked binary through the App
> Store (and likely external TestFlight) conflicts with Apple's Usage Rules /
> DRM under GPL §6/§10. OpenRung cannot resolve this for the sing-box portion
> alone — resolve it before any public App Store release (exception from
> SagerNet, or move to an out-of-process engine).

`Libbox.xcframework` is generated locally from sing-box and intentionally
ignored by git because it is large.

To rebuild it against the pinned revision (run from the repo root):

```sh
# SINGBOX_VERSION holds a Go pseudo-version like
# v0.0.0-<utc>-<12-char-commit>; the trailing 12 chars are the commit SHA.
version="$(tr -d '[:space:]' < SINGBOX_VERSION)"
commit="${version##*-}"

git clone https://github.com/SagerNet/sing-box.git /private/tmp/openrung-sing-box
cd /private/tmp/openrung-sing-box
git checkout "$commit"

go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
PATH="$HOME/go/bin:$PATH" gomobile init
PATH="$HOME/go/bin:$PATH" go run ./cmd/internal/build_libbox \
  -target apple -platform ios,iossimulator

# Copy the result back into this directory (adjust the destination to your checkout):
cp -R Libbox.xcframework "$OLDPWD/ios/ThirdParty/Libbox.xcframework"
```

The Android AAR is built from the same pinned revision by
[`../../android/build-libbox-release.sh`](../../android/build-libbox-release.sh).
