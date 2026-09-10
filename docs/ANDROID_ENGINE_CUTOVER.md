# ADR-003 B2: Android connectcore cutover

Android now runs published `connectcore/v0.6.0` as its sole connection
orchestrator. This is the actual B2 implementation after preparation PR #112
(mobile main `53e03d9`) and core API PR #179. There is no engine-selection flag.
Physical-device acceptance below remains pending; this is not release promotion.

## Ownership and API

`ConnectcoreProcessHost` retains one engine and durable outbox for the process.
Its serial queue joins Stop before replacing a VpnService owner, reuses the
engine across service recreation, and drops queued events/network observations
from retired attachments. Reapply runs in the same command order as disconnect.
Gomobile callbacks only enqueue; none calls Engine from a locked Go callback.

`NewOpenRungMobileEngineForAndroid` accepts the existing install UUID,
app/platform version, private telemetry directory, legacy preference batch,
and the app's coordinator certificate pins. It installs the `MobileHost` API,
protected broker/DNS/telemetry transport and the `openrungpunch` establisher.
It never changes HOME/XDG or builds an engine from unpublished source.

The host supplies fresh effective split settings and permission checks before
each candidate. Go preflights both direct and bridge graphs with CheckConfig
before remote failure may authorize WSS. Relay credentials, bridge endpoints,
DoH chain generation and all selection/recovery decisions remain in Go.

Each `AndroidEngineRun` owns one original TUN fd, one platform interface, one
captured VPN Network and one Go telemetry reporter. Libbox duplicates the fd.
Readiness resolves the exact fd's interface and waits for its VPN Network's
addresses/routes/DNS. Verification binds a fresh nonce DNS query and the pinned
HTTPS probe to that owner; missing ownership is local failure. Cancellation
closes blocking probe sockets and joins workers. Only allow-listed remote
DNS/HTTPS failures produce `RemotePathError`; cancellation remains cancellation.

Shutdown cancels/joins native operations, stops libbox, reads final traffic,
drains reduced application counts and releases the original TUN fd. A failed
core close retains its native owner and prevents overlap. `TeardownComplete`
distinguishes incomplete runtime teardown from an upload failure: the latter
retains its backlog without permanently poisoning the engine.

`ClientIdentity` and `openrung_telemetry_outbox.jsonl` remain unchanged. Legacy
SharedPreferences rows are decoded with the shipping outbox rules; importable
rows must be durable before the preference is cleared. Corrupt rows retain the
previous discard behavior. Native flow attribution still excludes port 53 and
our own package, uses the same 15-minute reduction and drains the tail once.
Retired callbacks cannot enter a successor's session. Go owns heartbeat,
session events, cumulative traffic, upload batching and terminal flush.

## Independent parity evidence

Expectations come from shipping mobile main `53e03d9`, not from regenerating
A4 output. Core `mobile_test.go` records the same source for its public API
parity tests. Mobile consumes the tagged implementation without private hooks
in either release artifact.

| Shipping behavior | Current evidence |
| --- | --- |
| Mobile TUN/DoH, country/LAN/package bypass, probe priority | Existing Kotlin/Swift config-input and golden suites; retained China-bypass DNS/HTTPS regression checks; Go mobile preflight tests |
| Stop during launch; FATAL Start already closed its instance | Existing concrete libbox graft restart/teardown race tests |
| Ordered reapply/disconnect, old callbacks, service recreation | `EngineProcessHostTest`, `EngineEventDispatcherTest` |
| Pause/wake publishes current network before resume | Native host ordering test and tagged Go lifecycle/network suites |
| Native probe cancellation and join before TUN release | `ProbeResourceTest`, `engine_mobile_libbox_test.go` |
| HTTPS-only coordinators, exact app pins, protected dialer, no redirects | `engine_mobile_punch_test.go`; existing leaf pin/validity tests |
| Stable install ID, shared store and legacy durability | Mobile constructor graft tests and retained Go outbox migration/locking tests |
| Reduced app flows, final traffic and retired reporters | `RunApplicationConnectionsTest`, existing aggregator tests, tagged mobile telemetry/teardown tests |
| Relay/session metadata and recents | Atomic Details in the tagged state API, same native display-name sanitizer, owner-filtered event projection |

A4's seven unmodified scenarios also run through the real generated JNI binding
and `EngineEventDispatcher` on the Pixel_10 arm64 emulator (Android 17/API 37).
Kotlin issues the lifecycle commands and compares delivered status/notice and
collected telemetry streams to the vendored vectors. Deterministic network,
clock and tunnel-process seams are exposed only in a temporary copy of the tag;
the shared harness is excluded from release grafts. These preserve A4's original
proxy-mode engine contract; the mobile host, real TUN and platform mechanics
have separate tests and device gates. Kotlin is now `local_suites`; Swift A4
integration remains B3 work.

Reproduce with one booted adb device (or set ANDROID_SERIAL):

```sh
python3 scripts/test-engine-vectors.py -race
python3 scripts/test-android-engine-vectors.py
bash android/build-libbox-release.sh
(cd android && ./gradlew --no-daemon :app:testDebugUnitTest)
```

The JNI runner builds a separate AAR, application ID `.enginecontract`, and
output directory. It never overwrites the release AAR or the existing installed
app. Gradle refuses release tasks with the test-AAR property. Android CI runs
both the normal unit suite and the Kotlin JNI suite on an x86_64 emulator.

Local validation on 2026-09-10: app 0.3.8, Go 1.26.4, macOS arm64; TypeScript,
25 Jest suites/300 tests, standalone Go race suite, tagged Go mobile tests,
169 Android unit tests, seven Kotlin JNI sequences, both native release builds and
ABI guards, and 167 iOS tests with Thread Sanitizer. CI uses Go 1.25.

## Resolved divergences

- The pin includes upstream's explicit port-53 DNS hijack ahead of bypass rules.
  Both platform golden suites assert that extra rule; the original DNS protocol
  match, probe priority and UDP/443 rejection remain.
- Physical liveness during recovery now follows connectcore's protected TCP
  checks of broker fronts, replacing Android's neutral gstatic/Cloudflare HTTP
  probes. Recovery waits until a front is reachable; broker blocking can therefore
  hold recovery even if unrelated internet traffic works. This is an explicit
  review point for censored-network beta validation, not tunnel-health evidence.
- Unusable/non-HTTPS/unpinned-IP punch endpoints are rejected by the transport
  adapter before dialing. Go may record a failed punch attempt before RelayHub
  fallback where the old Kotlin wrapper silently skipped constructing a client.
  Deployed app certificate pins and CA verification for hostnames are preserved.
- A sticky restart with no connect intent clears unfinished status and returns
  to DISCONNECTED. Terminal failure survives the service's subsequent onDestroy;
  the user must connect again after process death. Pending durable telemetry is
  retained for the next engine session.
- Connection diagnostics now come from Go; localized UI status labels remain
  native. Session identity/metadata is the tagged engine's, including app version,
  platform, orchestrator and engine version. Older native sessions are identified
  using their known release/build versions where no orchestrator field exists.

## Remaining physical-device acceptance

No physical Android device was attached. Emulator/JVM results do not establish
these checks, and the PR remains draft until their evidence is recorded:

- Stop during real TUN startup; rapid disconnect/reconnect with stale callbacks.
- protect() refusal and protected socket ownership while the VPN is active.
- Wi-Fi/cellular handover, paused epoch changes, sleep/wake and service restart.
- Pending telemetry across teardown and process restart, including final byte and
  per-app flow counts on a real VPN session.
- Representative restricted networks for the changed physical-liveness gate.

Record device/OS, build SHA, network, steps, logs and expected/observed results.
Track C beta/public promotion and B3's running-iOS memory budget remain separate.
