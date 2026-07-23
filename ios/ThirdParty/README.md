# Third-party iOS engine artifacts

> **License / GPL corresponding source.** sing-box is **GPL-3.0-or-later** and
> `Libbox.xcframework` is statically linked into the app and the PacketTunnel
> extension, so the whole iOS app is GPL-3.0-or-later (see the repo `LICENSE`
> and `THIRD_PARTY_NOTICES.md`). The build below pins the **exact sing-box
> revision** recorded in [`../../SINGBOX_VERSION`](../../SINGBOX_VERSION). The
> OpenRung WSS wrapper also resolves the exact `wsscore` tag pinned in
> [`../../android/punchbridge/go.mod`](../../android/punchbridge/go.mod), so the
> GPL §6 corresponding source is reproducible — keep those pins in lockstep
> with the shipped binary (see [`../../RELEASE.md`](../../RELEASE.md)).
>
> **App Store caveat:** distributing this GPL-linked binary through the App
> Store (and likely external TestFlight) conflicts with Apple's Usage Rules /
> DRM under GPL §6/§10. OpenRung cannot resolve this for the sing-box portion
> alone — resolve it before any public App Store release (exception from
> SagerNet, or move to an out-of-process engine).

`Libbox.xcframework` is generated locally from sing-box and intentionally
ignored by git because it is large.

To rebuild both the iOS device and simulator slices (run from the repo root):

```sh
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
PATH="$(go env GOPATH)/bin:$PATH" gomobile init
./ios/build-libbox-release.sh
```

The script downloads the exact sing-box pseudo-version, grafts only the thin
OpenRung WSS binding into `experimental/libbox`, trims sing-box's libbox build
tags to OpenRung's feature set (dropping Tailscale, WireGuard, and naiveproxy —
see [`../../RELEASE.md`](../../RELEASE.md) §2), resolves the tagged `wsscore`
module, and emits one unified `Libbox.xcframework`. This is required because a
second gomobile framework would load a second, incompatible Go runtime. The
transport implementation is never copied into this repository.

For development against an unpublished local wsscore checkout, use
`WSSCORE_SRC=/absolute/path/to/wsscore ./ios/build-libbox-release.sh`. Artifacts
built this way are explicitly non-release builds; omit `WSSCORE_SRC` to verify
the pinned tag used for distribution.

The Android AAR is built from the same pinned revision by
[`../../android/build-libbox-release.sh`](../../android/build-libbox-release.sh).
