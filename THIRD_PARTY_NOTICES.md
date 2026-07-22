# Third-Party Notices

The OpenRung mobile app is distributed with, links against, or bundles the
third-party components listed below. This file reproduces the copyright notices
and license information those components require us to carry when we distribute
the apps.

It is the single source of truth for attribution. The Android and iOS apps
render these notices in the in-app "Open Source Licenses" screen
(`src/licenses/notices.ts` is generated from this file plus `LICENSE`).

This repository ships only the two mobile apps (Android APK, iOS app +
PacketTunnel extension). Server-side components (broker, relay, relay hub)
live in the production OpenRung repository and carry their own notices there.

> Maintenance: when a dependency that ships to users is added, removed, or
> upgraded, update this file. The sing-box / Libbox transitive set (below)
> should be captured from the **exact sing-box commit** the release was built
> against — see "Corresponding source," below.

---

## 1. Strong copyleft (GPL) — controls both apps

### sing-box (libbox) — GPL-3.0-or-later

- **Component:** `github.com/SagerNet/sing-box` (the `libbox` mobile library:
  `android/app/libs/libbox.aar`, `ios/ThirdParty/Libbox.xcframework`)
- **License:** GNU General Public License v3.0 or later (**GPL-3.0-or-later**),
  with an additional permitted term.
- **Upstream:** https://github.com/SagerNet/sing-box
- **License text:** https://github.com/SagerNet/sing-box/blob/main/LICENSE
  (the full GPL-3.0 text is also bundled in this repository as `LICENSE`).
- **Additional term (GPL-3.0 §7, must be preserved):**
  *"In addition, no derivative work may use the name or imply association with
  this application without prior consent."*

sing-box is **statically linked** into the OpenRung Android APK and iOS app.
Under GPL-3.0 §5, the resulting combined work — including OpenRung's own
first-party code in those apps — is licensed to recipients under
**GPL-3.0-or-later**. This app as a whole is licensed under
GPL-3.0-or-later (see `LICENSE`), same as the production OpenRung project.

OpenRung is **not affiliated with or endorsed by** sing-box or SagerNet; the
sing-box name is used only descriptively.

### OpenRung wsscore — GPL-3.0-or-later

- **Component:** `github.com/openrung/openrung/wsscore` at the exact version
  pinned in `android/punchbridge/go.mod` (linked into both Libbox artifacts).
- **License:** GNU General Public License v3.0 or later.
- **Upstream/source:** https://github.com/openrung/openrung/tree/main/wsscore

This is first-party shared transport code rather than a third-party project,
but it is called out because its tagged source and transitive dependencies are
separate native release inputs. The complete GPL-3.0 text is bundled as
`LICENSE`.

#### sing-box transitive components (compiled into the apps)

The `libbox` build statically links additional libraries that are therefore
distributed inside the apps. This list must be completed from the exact build
(`go-licenses` against the sing-box module); the notable ones include:

- `gvisor.dev/gvisor` — Apache-2.0 (ships a NOTICE file that must be reproduced)
- `github.com/sagernet/quic-go` (SagerNet's sing-box fork of quic-go) — MIT
- `golang.zx2c4.com/wireguard` (wireguard-go) — MIT
- `github.com/refraction-networking/utls` — BSD-3-Clause
- `github.com/gorilla/websocket` — BSD-2-Clause, Copyright (c) 2013 The
  Gorilla WebSocket Authors
- `github.com/hashicorp/yamux` — MPL-2.0, Copyright (c) 2014 HashiCorp, Inc.
- `github.com/sagernet/sing`, `sing-quic`, `sing-shadowsocks*`, and related
  `sagernet/*` modules — GPL-3.0 / mixed (reinforces the GPL-3.0 result above)
- Go standard library / runtime — BSD-3-Clause, Copyright (c) The Go Authors
  (source: https://github.com/golang/go)

---

## 2. React Native layer (MIT) — bundled in both apps

The JavaScript bundle and the native modules of these packages are distributed
inside both apps. All are MIT-licensed; the MIT text is reproduced in
Appendix A.

### React Native

- **Component:** `react-native` 0.86.0 (framework, Hermes JS engine, and the
  `react` 19.2.3 runtime it depends on).
- **License:** MIT — Copyright (c) Meta Platforms, Inc. and affiliates.
- **Upstream:** https://github.com/facebook/react-native
- Note: React Native bundles further native third-party code (Hermes, fbjni,
  folly, glog and friends — MIT / Apache-2.0 / BSD; on Android also OkHttp /
  okio (Apache-2.0) and Fresco (MIT)). Their notices are carried in the
  react-native package and should be reproduced for store releases.

### @maplibre/maplibre-react-native

- **Component:** `@maplibre/maplibre-react-native` 11.3.6 (React Native
  bindings for MapLibre Native; renders the exit-node map).
- **License:** MIT — Copyright (c) 2022 MapLibre contributors,
  Copyright (c) 2015-2020 Mapbox.
- **Upstream:** https://github.com/maplibre/maplibre-react-native

### @react-native-async-storage/async-storage

- **Component:** `@react-native-async-storage/async-storage` 3.1.1 (persists
  the language selection).
- **License:** MIT.
- **Upstream:** https://github.com/react-native-async-storage/async-storage

### react-native-safe-area-context

- **Component:** `react-native-safe-area-context` 5.x.
- **License:** MIT — Copyright (c) 2019 Th3rd Wave.
- **Upstream:** https://github.com/AppAndFlow/react-native-safe-area-context

### react-native-svg

- **Component:** `react-native-svg` 15.x (SVG rendering for the tab-bar and
  connect-button icons and the home-screen map edge vignette; ships a native
  module in both apps — `RNSVG` pod on iOS, `com.horcrux.svg` on Android).
- **License:** MIT — Copyright (c) 2015 Software Mansion.
- **Upstream:** https://github.com/software-mansion/react-native-svg

---

## 3. MapLibre Native SDKs (BSD-2-Clause)

`@maplibre/maplibre-react-native` embeds the MapLibre Native map renderer in
each app:

- **Android:** `org.maplibre.gl:android-sdk` (MapLibre Native) — Copyright (c)
  MapLibre contributors (2021), MapTiler.com (2018-2021), Mapbox (2014-2020).
  License: BSD-2-Clause.
- **iOS:** `MapLibre` (MapLibre Native for iOS, via CocoaPods) — same
  copyright holders and license.

The SDK also aggregates further third-party notices in its `LICENSE.md`
(https://github.com/maplibre/maplibre-native/blob/main/LICENSE.md), which
should be reproduced in the in-app notices.

OpenRung is not affiliated with or endorsed by the MapLibre project; the name
is used descriptively.

---

## 4. Apache-2.0 (reproduce each component's NOTICE file, not just the license)

Bundled in the Android APK:

- `org.jetbrains.kotlin:kotlin-stdlib` (Apache-2.0; also bundles Boost-1.0 and
  fdlibm/SUN-licensed math portions that must be acknowledged)
- `org.jetbrains.kotlinx:kotlinx-coroutines-android` 1.9.0
- `org.jetbrains.kotlinx:kotlinx-serialization-json` 1.7.3
- `androidx.*` libraries pulled in by React Native and the native modules
  (appcompat, core-ktx, and transitive AndroidX artifacts)

> Full Apache-2.0 text: https://www.apache.org/licenses/LICENSE-2.0

---

## 5. Components that are NOT distributed (no obligation)

Listed so they are deliberately **excluded** from the shipped notices: dev and
test dependencies (Jest, ESLint, Prettier, Babel toolchain, TypeScript,
`react-test-renderer`, `@react-native-community/cli`), build tools
(`sagernet/gomobile`/`gobind`, Gradle, xcodegen, CocoaPods), and Metro (dev
server only; its runtime output is covered by the react-native license). The
MapLibre **demo tiles and glyph fonts** at `demotiles.maplibre.org` are fetched
at runtime and not bundled, so no redistribution obligation attaches (but that
demo endpoint is not intended for production traffic — move to a
self-hosted/licensed source before scaling).

---

## Corresponding source (GPL-3.0 §6)

The complete corresponding source for any distributed OpenRung mobile app
binary — this repository's source, the pinned sing-box revision, and the build
scripts — is available from the app's source repository:
**https://github.com/openrung/openrung-mobile-app**.

The apps statically link a specific sing-box commit. That commit is pinned in
this repository at [`SINGBOX_VERSION`](SINGBOX_VERSION). Android's same-runtime
AAR also includes the first-party native bindings under `android/punchbridge`
and the shared OpenRung punch and WSS cores, consumed as the Go modules
`github.com/openrung/openrung/punchcore` and
`github.com/openrung/openrung/wsscore` at the versions pinned in
`android/punchbridge/go.mod`. The Apple framework includes the WSS binding and
the same wsscore pin. Both cores are first-party GPL-3.0-or-later code; their
complete tagged source is available from **https://github.com/openrung/openrung**,
which this offer also covers. The build paths
(`android/build-libbox-release.sh` and `ios/build-libbox-release.sh`) and the
per-release procedure in [`RELEASE.md`](RELEASE.md) make both artifacts
reproducible. Record and verify the sing-box, punchcore, and wsscore pins against
every shipped binary. OpenRung will provide the corresponding source for at
least three (3) years on request.

---

## Appendix A — Standard short-form license texts

### The MIT License (MIT)

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### BSD 3-Clause License

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, ... (full
disclaimer as in the standard BSD-3-Clause text).
```

### BSD 2-Clause License

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED ... "AS IS" ... (full standard BSD-2-Clause disclaimer).
```

Full texts for Apache-2.0 are referenced by URL above; GPL-3.0 is bundled as
`LICENSE` in this repository.
