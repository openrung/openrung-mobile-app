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
- `github.com/hashicorp/yamux` v0.1.2 — MPL-2.0, Copyright (c) 2014
  HashiCorp, Inc. ([upstream](https://github.com/hashicorp/yamux/tree/v0.1.2);
  [MPL-2.0 license text](https://github.com/hashicorp/yamux/blob/v0.1.2/LICENSE),
  also published by the
  [Mozilla Foundation](https://www.mozilla.org/MPL/2.0/))
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

## Appendix A — License texts

### Mozilla Public License 2.0 (yamux)

The following text is reproduced verbatim from the pinned
`github.com/hashicorp/yamux` v0.1.2 `LICENSE` file:

```text
Copyright (c) 2014 HashiCorp, Inc.

Mozilla Public License, version 2.0

1. Definitions

1.1. "Contributor"

     means each individual or legal entity that creates, contributes to the
     creation of, or owns Covered Software.

1.2. "Contributor Version"

     means the combination of the Contributions of others (if any) used by a
     Contributor and that particular Contributor's Contribution.

1.3. "Contribution"

     means Covered Software of a particular Contributor.

1.4. "Covered Software"

     means Source Code Form to which the initial Contributor has attached the
     notice in Exhibit A, the Executable Form of such Source Code Form, and
     Modifications of such Source Code Form, in each case including portions
     thereof.

1.5. "Incompatible With Secondary Licenses"
     means

     a. that the initial Contributor has attached the notice described in
        Exhibit B to the Covered Software; or

     b. that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the terms of
        a Secondary License.

1.6. "Executable Form"

     means any form of the work other than Source Code Form.

1.7. "Larger Work"

     means a work that combines Covered Software with other material, in a
     separate file or files, that is not Covered Software.

1.8. "License"

     means this document.

1.9. "Licensable"

     means having the right to grant, to the maximum extent possible, whether
     at the time of the initial grant or subsequently, any and all of the
     rights conveyed by this License.

1.10. "Modifications"

     means any of the following:

     a. any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered Software; or

     b. any new file in Source Code Form that contains any Covered Software.

1.11. "Patent Claims" of a Contributor

      means any patent claim(s), including without limitation, method,
      process, and apparatus claims, in any patent Licensable by such
      Contributor that would be infringed, but for the grant of the License,
      by the making, using, selling, offering for sale, having made, import,
      or transfer of either its Contributions or its Contributor Version.

1.12. "Secondary License"

      means either the GNU General Public License, Version 2.0, the GNU Lesser
      General Public License, Version 2.1, the GNU Affero General Public
      License, Version 3.0, or any later versions of those licenses.

1.13. "Source Code Form"

      means the form of the work preferred for making modifications.

1.14. "You" (or "Your")

      means an individual or a legal entity exercising rights under this
      License. For legal entities, "You" includes any entity that controls, is
      controlled by, or is under common control with You. For purposes of this
      definition, "control" means (a) the power, direct or indirect, to cause
      the direction or management of such entity, whether by contract or
      otherwise, or (b) ownership of more than fifty percent (50%) of the
      outstanding shares or beneficial ownership of such entity.


2. License Grants and Conditions

2.1. Grants

     Each Contributor hereby grants You a world-wide, royalty-free,
     non-exclusive license:

     a. under intellectual property rights (other than patent or trademark)
        Licensable by such Contributor to use, reproduce, make available,
        modify, display, perform, distribute, and otherwise exploit its
        Contributions, either on an unmodified basis, with Modifications, or
        as part of a Larger Work; and

     b. under Patent Claims of such Contributor to make, use, sell, offer for
        sale, have made, import, and otherwise transfer either its
        Contributions or its Contributor Version.

2.2. Effective Date

     The licenses granted in Section 2.1 with respect to any Contribution
     become effective for each Contribution on the date the Contributor first
     distributes such Contribution.

2.3. Limitations on Grant Scope

     The licenses granted in this Section 2 are the only rights granted under
     this License. No additional rights or licenses will be implied from the
     distribution or licensing of Covered Software under this License.
     Notwithstanding Section 2.1(b) above, no patent license is granted by a
     Contributor:

     a. for any code that a Contributor has removed from Covered Software; or

     b. for infringements caused by: (i) Your and any other third party's
        modifications of Covered Software, or (ii) the combination of its
        Contributions with other software (except as part of its Contributor
        Version); or

     c. under Patent Claims infringed by Covered Software in the absence of
        its Contributions.

     This License does not grant any rights in the trademarks, service marks,
     or logos of any Contributor (except as may be necessary to comply with
     the notice requirements in Section 3.4).

2.4. Subsequent Licenses

     No Contributor makes additional grants as a result of Your choice to
     distribute the Covered Software under a subsequent version of this
     License (see Section 10.2) or under the terms of a Secondary License (if
     permitted under the terms of Section 3.3).

2.5. Representation

     Each Contributor represents that the Contributor believes its
     Contributions are its original creation(s) or it has sufficient rights to
     grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

     This License is not intended to limit any rights You have under
     applicable copyright doctrines of fair use, fair dealing, or other
     equivalents.

2.7. Conditions

     Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted in
     Section 2.1.


3. Responsibilities

3.1. Distribution of Source Form

     All distribution of Covered Software in Source Code Form, including any
     Modifications that You create or to which You contribute, must be under
     the terms of this License. You must inform recipients that the Source
     Code Form of the Covered Software is governed by the terms of this
     License, and how they can obtain a copy of this License. You may not
     attempt to alter or restrict the recipients' rights in the Source Code
     Form.

3.2. Distribution of Executable Form

     If You distribute Covered Software in Executable Form then:

     a. such Covered Software must also be made available in Source Code Form,
        as described in Section 3.1, and You must inform recipients of the
        Executable Form how they can obtain a copy of such Source Code Form by
        reasonable means in a timely manner, at a charge no more than the cost
        of distribution to the recipient; and

     b. You may distribute such Executable Form under the terms of this
        License, or sublicense it under different terms, provided that the
        license for the Executable Form does not attempt to limit or alter the
        recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

     You may create and distribute a Larger Work under terms of Your choice,
     provided that You also comply with the requirements of this License for
     the Covered Software. If the Larger Work is a combination of Covered
     Software with a work governed by one or more Secondary Licenses, and the
     Covered Software is not Incompatible With Secondary Licenses, this
     License permits You to additionally distribute such Covered Software
     under the terms of such Secondary License(s), so that the recipient of
     the Larger Work may, at their option, further distribute the Covered
     Software under the terms of either this License or such Secondary
     License(s).

3.4. Notices

     You may not remove or alter the substance of any license notices
     (including copyright notices, patent notices, disclaimers of warranty, or
     limitations of liability) contained within the Source Code Form of the
     Covered Software, except that You may alter any license notices to the
     extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

     You may choose to offer, and to charge a fee for, warranty, support,
     indemnity or liability obligations to one or more recipients of Covered
     Software. However, You may do so only on Your own behalf, and not on
     behalf of any Contributor. You must make it absolutely clear that any
     such warranty, support, indemnity, or liability obligation is offered by
     You alone, and You hereby agree to indemnify every Contributor for any
     liability incurred by such Contributor as a result of warranty, support,
     indemnity or liability terms You offer. You may include additional
     disclaimers of warranty and limitations of liability specific to any
     jurisdiction.

4. Inability to Comply Due to Statute or Regulation

   If it is impossible for You to comply with any of the terms of this License
   with respect to some or all of the Covered Software due to statute,
   judicial order, or regulation then You must: (a) comply with the terms of
   this License to the maximum extent possible; and (b) describe the
   limitations and the code they affect. Such description must be placed in a
   text file included with all distributions of the Covered Software under
   this License. Except to the extent prohibited by statute or regulation,
   such description must be sufficiently detailed for a recipient of ordinary
   skill to be able to understand it.

5. Termination

5.1. The rights granted under this License will terminate automatically if You
     fail to comply with any of its terms. However, if You become compliant,
     then the rights granted under this License from a particular Contributor
     are reinstated (a) provisionally, unless and until such Contributor
     explicitly and finally terminates Your grants, and (b) on an ongoing
     basis, if such Contributor fails to notify You of the non-compliance by
     some reasonable means prior to 60 days after You have come back into
     compliance. Moreover, Your grants from a particular Contributor are
     reinstated on an ongoing basis if such Contributor notifies You of the
     non-compliance by some reasonable means, this is the first time You have
     received notice of non-compliance with this License from such
     Contributor, and You become compliant prior to 30 days after Your receipt
     of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
     infringement claim (excluding declaratory judgment actions,
     counter-claims, and cross-claims) alleging that a Contributor Version
     directly or indirectly infringes any patent, then the rights granted to
     You by any and all Contributors for the Covered Software under Section
     2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all end user
     license agreements (excluding distributors and resellers) which have been
     validly granted by You or Your distributors under this License prior to
     termination shall survive termination.

6. Disclaimer of Warranty

   Covered Software is provided under this License on an "as is" basis,
   without warranty of any kind, either expressed, implied, or statutory,
   including, without limitation, warranties that the Covered Software is free
   of defects, merchantable, fit for a particular purpose or non-infringing.
   The entire risk as to the quality and performance of the Covered Software
   is with You. Should any Covered Software prove defective in any respect,
   You (not any Contributor) assume the cost of any necessary servicing,
   repair, or correction. This disclaimer of warranty constitutes an essential
   part of this License. No use of  any Covered Software is authorized under
   this License except under this disclaimer.

7. Limitation of Liability

   Under no circumstances and under no legal theory, whether tort (including
   negligence), contract, or otherwise, shall any Contributor, or anyone who
   distributes Covered Software as permitted above, be liable to You for any
   direct, indirect, special, incidental, or consequential damages of any
   character including, without limitation, damages for lost profits, loss of
   goodwill, work stoppage, computer failure or malfunction, or any and all
   other commercial damages or losses, even if such party shall have been
   informed of the possibility of such damages. This limitation of liability
   shall not apply to liability for death or personal injury resulting from
   such party's negligence to the extent applicable law prohibits such
   limitation. Some jurisdictions do not allow the exclusion or limitation of
   incidental or consequential damages, so this exclusion and limitation may
   not apply to You.

8. Litigation

   Any litigation relating to this License may be brought only in the courts
   of a jurisdiction where the defendant maintains its principal place of
   business and such litigation shall be governed by laws of that
   jurisdiction, without reference to its conflict-of-law provisions. Nothing
   in this Section shall prevent a party's ability to bring cross-claims or
   counter-claims.

9. Miscellaneous

   This License represents the complete agreement concerning the subject
   matter hereof. If any provision of this License is held to be
   unenforceable, such provision shall be reformed only to the extent
   necessary to make it enforceable. Any law or regulation which provides that
   the language of a contract shall be construed against the drafter shall not
   be used to construe this License against a Contributor.


10. Versions of the License

10.1. New Versions

      Mozilla Foundation is the license steward. Except as provided in Section
      10.3, no one other than the license steward has the right to modify or
      publish new versions of this License. Each version will be given a
      distinguishing version number.

10.2. Effect of New Versions

      You may distribute the Covered Software under the terms of the version
      of the License under which You originally received the Covered Software,
      or under the terms of any subsequent version published by the license
      steward.

10.3. Modified Versions

      If you create software not governed by this License, and you want to
      create a new license for such software, you may create and use a
      modified version of this License if you rename the license and remove
      any references to the name of the license steward (except to note that
      such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
      Licenses If You choose to distribute Source Code Form that is
      Incompatible With Secondary Licenses under the terms of this version of
      the License, the notice described in Exhibit B of this License must be
      attached.

Exhibit A - Source Code Form License Notice

      This Source Code Form is subject to the
      terms of the Mozilla Public License, v.
      2.0. If a copy of the MPL was not
      distributed with this file, You can
      obtain one at
      http://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular file,
then You may include the notice in a location (such as a LICENSE file in a
relevant directory) where a recipient would be likely to look for such a
notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice

      This Source Code Form is "Incompatible
      With Secondary Licenses", as defined by
      the Mozilla Public License, v. 2.0.
```

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

Full texts for Apache-2.0 and yamux's MPL-2.0 are referenced by URL above;
GPL-3.0 is bundled as `LICENSE` in this repository.
