# ADR-003 B3: Swift connectcore cutover

Swift now uses published `connectcore/v0.6.1` as its sole VPN orchestrator.
The baseline for independent expectations is mobile main `e1dc94c` (B2 merged;
iOS still native). The React Native surface and VPN profile format remain the
same. No runtime engine selector is present.

## Ownership and compatibility

`PacketTunnelEngineHost` owns one engine and outbox per extension process.
It serializes start/stop/sleep/wake, joins teardown before replacing the provider,
and uses attachment identities to discard buffered callbacks and observations
from retired providers. Go callbacks only enqueue; synchronous host callbacks
borrow the provider under a separate lock so shutdown cannot deadlock on the
control queue. Start completion is delivered once, after either verified
connection or joined cancellation/failure.

`NewOpenRungMobileEngineForIOS` installs Apple's provider-socket ownership,
mobile host settings, concrete libbox runtime, and the pinned/published punch
establisher. Non-iOS runtimes cannot use its nil-protector constructor. Swift
supplies fresh TUN/split settings before each candidate. Go owns relay/ranking,
configuration preflight, DNS chains, direct/punch/RelayHub/WSS selection,
tickets, health, recovery and telemetry.

Each `IOSPacketTunnelRun` retains one immutable provider and platform interface.
The settings completion and provider TUN fd establish readiness. NE owns the
original descriptor; libbox duplicates it. DNS/HTTPS evidence comes only from
Apple's explicit provider-through-tunnel APIs. Cancellation cancels Swift tasks,
closes their native connections and joins cleanup before Go releases the run.
Native error facts preserve timeout/DNS/TLS/errno taxonomy through Go's existing
classifier; unknown/platform errors remain local.

Stop cancels/joins operations, stops libbox, reads final aggregate traffic,
and clears NE settings during candidate replacement. Once `stopTunnel` begins,
NetworkExtension owns settings withdrawal and can reject a late explicit clear
with `NEAgentErrorDomain`; that rejection must not poison an already closed
libbox run. Other native settings/close failures still fail closed. Incomplete
teardown retains the provider, permanently
rejects reuse in that process and calls `cancelTunnelWithError`; NetworkExtension
owns final process/resource reclamation. A telemetry upload timeout alone keeps
the backlog and permits reuse. iOS continues to omit per-application attribution.
The original app-group install UUID, `outbox.json` (including array-format
migration), and `telemetry_session` storage format are retained. There is no
second Swift outbox/heartbeat manager. Engine telemetry carries app version,
platform and connectcore identity for Track C; older native sessions remain
identifiable by known release versions.

## Independent parity evidence

| Shipping requirement/source at `e1dc94c` | B3 evidence |
| --- | --- |
| Stop joins startup before completing; rapid replacement cannot resurrect a provider (`PacketTunnelProvider`) | `EngineHostTests`: cancellation, blocked teardown, old events/network/stop, engine reuse and one-shot completions |
| Teardown failure must not overlap live TUN owners (B1 runtime contract) | Go concrete runtime race tests; Swift poisoned-host/retained-owner tests |
| Initial/duplicate/changed NWPath and sleep/wake semantics (`PhysicalNetworkEpochMonitor`, provider) | `EngineAdapterTests` fingerprints; `EngineHostTests` pause → changed epoch → resume; concrete libbox pause-before-launch and retired-wake test |
| Fresh DNS plus priority-pinned HTTPS through NE, derived DoH deadlines (`PacketTunnelDnsProbe`, `PacketTunnelInternetProbe`) | Existing Swift DNS/HTTPS tests; cancellation/join and typed-error adapter tests; transport regression guard |
| iOS TUN/split configuration, no per-app exclusion (`SingBoxConfiguration`, `SplitTunnelConfig`) | Existing config/golden tests plus `EngineTunnelSettings` comparison to shipping assembly; retained bridge/descriptor regression tests |
| Display metadata/recents clear on recovery/failure (`SharedConnectionState`) | Existing state tests plus atomic engine projection/sanitization/stale-recent tests |
| Stable install identity and pending telemetry across upgrades (`ClientIdentity`, `TelemetryClient`) | Go iOS constructor test loads the shipping `outbox.json` array, verifies backlog and identity, and rejects a second owner; shared outbox durability tests |
| Real generated Swift binding and engine sequencing (A4) | All seven unchanged vectors through `scripts/test-ios-engine-vectors.py`; Swift moves to `local_suites` |

A4 validates the frozen engine contract and does not replace independently
reviewed shipping expectations or physical TUN testing. Obsolete policy tests
were removed with their implementations; ADR-001 classification input coverage
retains only historical error fixtures outside shipping targets.

## Resolved divergences

- Shared recovery follows v0.6.1: usable neutral HTTPS or broker-front TCP can
  permit recovery; known-down physical paths skip probes; outage retries back
  off within the shared two-minute recovery budget. A terminal outage requires
  a new user connect. These are the same tagged semantics accepted in B2.
- Go supplies connection diagnostics and session metadata. Existing native UI
  status labels and the geographic/display-name separation remain.
- Wake explicitly wakes libbox's pause manager before resuming connectcore.
  The pinned libbox `CommandServer.Wake` method does nothing on iOS; using it
  directly would resume health checks while the data plane could still be
  paused. Sleep arriving during native startup records its state without
  blocking the host control queue; startup applies it before reporting ready.
  The existing one-minute automatic data-plane wake remains while
  asleep; explicit wake/close cancels that timer. Duplicate paths/wake do not
  themselves retire a healthy WSS session.
- iOS aggregate traffic retains its one-minute sampling cadence and a final
  read after close. The in-process runtime no longer needs a gRPC listener or
  secret to obtain these counters. Android retains its one-second cadence.
- The initial NWPath observation is now sent before the first engine Start;
  absence for five seconds fails locally instead of starting with unknown
  physical state. Cost/capability/interface changes retain their fingerprint
  semantics. Native settings are refreshed per engine candidate.
- Invalid/unpinned punch coordinators are rejected in the shared transport;
  an attempted punch may be recorded before RelayHub fallback where the old
  Swift wrapper skipped constructing a client. App certificate pins remain.
- NetworkExtension owns settings removal after its stop callback. Candidate
  replacement explicitly clears settings; only an actual OS-stop handoff can
  suppress a concurrently rejected settings request. This fixes the physical
  device teardown regression exposed by the B3 test.
- Incomplete native close is surfaced instead of ignored. The extension asks
  NetworkExtension to end the tunnel and cannot attach another owner until a
  new process. Historical relay/config error adapters are test fixtures only.

## Reproduce

```sh
bash ios/build-libbox-release.sh
bash ios/scripts/generate-project.sh
xcodebuild -project ios/OpenRung.xcodeproj -scheme OpenRungTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -enableThreadSanitizer YES -parallel-testing-enabled NO test
python3 scripts/test-ios-engine-vectors.py
python3 scripts/test-engine-vectors.py -race
bash android/build-libbox-release.sh
(cd android && ./gradlew --no-daemon :app:testDebugUnitTest)
npx tsc --noEmit
npm test -- --runInBand
npm run contract:check
npm run transport:check
```

The Swift A4 runner builds an isolated framework/project and never overwrites
the release XCFramework. Only the existing network/clock/process seams in a
temporary copy of the exact tag are exposed; no test API ships. No iOS CI job
is claimed.

For an explicitly selected physical iPhone with an already prepared OpenRung
VPN profile, the opt-in hosted `EngineDeviceTests` scheme uses the signed app
and existing profile, exercises stop-during-start and two live reconnects,
checks identity/state, and leaves the tunnel stopped. It installs the local
build over that app. A disabled profile is temporarily enabled, as the app
connect path does; its original enabled setting is restored after the test.
The stored country/relay selection is temporarily cleared so stale relay IDs
do not block the lifecycle test, then restored from a copy of the original
profile. Broker and split settings are preserved. Do not interact with the app
while this opt-in suite is running.

```sh
xcodebuild -workspace ios/OpenRung.xcworkspace -scheme EngineDeviceTests \
  -configuration Release -destination 'platform=iOS,id=<device UDID>' \
  -allowProvisioningUpdates -parallel-testing-enabled NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=OPENRUNG_MEMORY_DIAGNOSTICS test
```

`OPENRUNG_MEMORY_DIAGNOSTICS` enables one-second `TASK_VM_INFO.phys_footprint`
samples, stage markers, and `engine-memory.json` in the app group. The report
contains current footprint, sampled peak, sample count and build version; it
contains no network credentials. Device XCTest attaches each cycle's report.
This Release compile condition is a diagnostic, not an engine-selection flag.
Sampling can miss shorter peaks; Instruments/jetsam evidence remains useful.
When `OPENRUNG_IOS_MEMORY_BUDGET_MIB` is set in the test process environment,
the device suite compares its sampled peak to that supplied limit. An absent
limit means measurement only, never a memory-budget pass.

## Validation recorded 2026-09-12

- Swift: 106 logic/platform tests passed with Thread Sanitizer; all seven
  unchanged A4 scenarios passed through the generated Swift binding.
- Android: 176 unit tests passed against the rebuilt release AAR; all seven
  A4 scenarios passed through Kotlin/JNI on the Android 17 emulator.
- Both release artifacts and ABI smoke checks passed, including concrete
  libbox race tests. Standalone Go race tests and Go A4 vectors passed.
- TypeScript, 25 Jest suites / 300 tests, ESLint (warnings only), and the
  version/transport/contract guards passed.
- Signed Release on iPhone 17 Pro Max, iOS 27 beta (24A5418b), app 0.3.8 (14),
  connectcore v0.6.1: stop during start followed by two actual TUN connections,
  20-second holds, clean disconnect/reconnect, metadata/session cleanup and
  unchanged install identity passed. The test restored the original VPN profile
  and left it stopped. Successful DNS/HTTPS verification used the provider's
  through-tunnel APIs; broker/relay outer traffic used provider-owned sockets.

The physical suite initially exposed a false teardown failure when NE rejected
settings removal after OS stop. The fix and regression test are included; the
final physical suite passed all assertions in 49 seconds. Its sampled peaks
were **15.78 MiB** and **15.91 MiB**, recorded in
[cycle 1](evidence/adr003-b3-ios/cycle-1-memory.json) and
[cycle 2](evidence/adr003-b3-ios/cycle-2-memory.json). Both saved reports satisfy
the 30 MiB short-session check (see
[validation](evidence/adr003-b3-ios/validation.json)). Earlier diagnostic runs,
including failed teardown runs, reached 27.50 MiB. These short direct-path
samples are below the 30 MiB gate, but do not establish a pass across all
transports/network conditions. No iOS CI or field-soak pass is claimed.

## Acceptance still requiring evidence

The B3 acceptance budget is **30 MiB peak physical footprint**, selected during
this implementation discussion on 2026-09-12. This is a validation gate, not
a runtime allocation cap or a change to the OS memory limit. Apple reported
50 MiB for packet tunnels on iOS 16–18 but warns that limits can vary and
change; 100 MiB would not be a useful protection against those OS ceilings
([Apple DTS](https://developer.apple.com/forums/thread/73148)).

B1's idle measurement and these short direct sessions do not establish the
complete running-extension gate. Record physical Release traces under 30 MiB
covering directory/cache growth, direct/punch/WSS, network changes, sleep/wake
and teardown before B3 acceptance.

Real-device coverage must also record socket ownership, Wi-Fi/cellular changes,
pause/resume across a changed epoch, sleep/wake, provider/process restart and
pending telemetry on teardown/restart. Automated simulator tests and a successful
compile do not mark those cases passed. C1 internal/beta evidence and the
verified recovery release procedure remain required before public promotion.
The source baseline for restoring the Swift native implementation is `e1dc94c`;
a source revert alone cannot repair an installed engine build.
