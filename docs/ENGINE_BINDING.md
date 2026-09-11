# ADR-003 B1: engine lifecycle binding

B1 introduced the lifecycle binding; B2 now pins connectcore v0.6.0 and uses
its mobile host API as Android's sole orchestrator. iOS remains on its native
orchestrator until B3. The original B1 APIs and measurements below are retained
for compatibility and historical evidence. The current Android constructor,
parity checks and device gates are documented in [ANDROID_ENGINE_CUTOVER.md](ANDROID_ENGINE_CUTOVER.md).
There is no runtime engine selector.

## Native API

Call `Libbox.setup` / `LibboxSetup` with the platform's existing paths, logging,
and memory options before starting the engine. Construct inside the authorized
VpnService or PacketTunnel owner:

- `NewOpenRungEngineForAndroid(configJSON, PlatformInterface, OpenRungWSSProtector, OpenRungEngineListener)`
- `NewOpenRungEngineForIOS(configJSON, PlatformInterface, OpenRungEngineListener)`

Both return an `OpenRungEngine` interface plus a Go error (Java exception / Swift
throwing API). Android requires its protector; the iOS constructor refuses every
non-iOS runtime. The in-process runtime is fixed by the constructor. Every engine
wires an `openrungpunch` establisher, including when punching is disabled.
Coordination uses the engine-supplied HTTP client, retaining its socket hooks;
the UDP socket uses the same protected platform path. The bridge owns the whole
establishment so teardown releases both QUIC and UDP resources.

Configuration is a strict JSON object. Unknown fields and trailing data fail:

```json
{
  "mode": "tun",
  "mtu": 1400,
  "telemetry_directory": "/platform-owned/private-directory",
  "punch_enabled": true,
  "punch_url": ""
}
```

Omitted mode means `tun`; `proxy` is also supported for loopback hosts/tests.
Omitted/zero MTU means 1400. An empty telemetry directory keeps the engine's
in-memory outbox. The platform supplies a private directory for durable sessions.
Empty punch URL uses the signed relay's coordinator. TLS verification remains
enabled. The release graft (`scripts/graft-engine-binding.sh`, shared by both
release scripts) initializes connectcore's app version from `package.json`
before any engine goroutine runs.

| Method | Contract |
|---|---|
| `Start(brokerURL, country, relayID)` | Dispatch connect/switch; completion is asynchronous. Relay ID takes precedence over country. Empty strings mean no target. |
| `Disconnect()` | Request user disconnect; completion comes through the state stream. |
| `Stop(flushBudgetMillis)` | Join teardown and terminal telemetry flush. Zero uses connectcore's default; positive values bound the flush only. Returns flush errors and incomplete libbox teardown. Reusable after successful stop. |
| `Pause()` / `Resume()` | Suspend/resume engine monitoring, heartbeats, and recovery. The data plane remains under the OS/libbox lifecycle. |
| `NetworkChanged(up, fingerprint, dnsServersJSON)` | Publish physical-network state plus IP-literal DNS servers (`[]` clears them). Invalid DNS input changes neither DNS nor epoch state. |
| `StateJSON()` | Current connectcore state snapshot. |
| `TeardownComplete()` | Whether the in-process runtime has released its active service, independently of telemetry flush failure. |

Whole lifecycle mutations are serialized. Native callers should use an IO queue.
Publish the current physical DNS servers with `NetworkChanged` before the first
Android `Start`; protected name resolution requires that platform observation.
The engine owns one durable outbox lock for its process lifetime; `Stop` does not
close that outbox. Keep one engine per process and use stable, delegating platform
hooks that forward to the current OS owner across a VpnService recreation. Do not
construct competing engines over the same outbox file. Platform adapter work must
cover this ownership explicitly in B2/B3.

## Callback and runtime lifetime

`OpenRungEngineListener.OnEvent(string)` receives an envelope with `version: 1`,
an increasing `sequence`, `kind` (`state`, `notice`, or `log`), and `payload`.
Payload fields use connectcore's Go JSON names: for example state `Status`,
`RelayLabel`, `LastError`, `Recents`, and notice `Kind`, `RelayID`, `FrontID`.
The native adapter translates these into its existing RN state model.

Callbacks run synchronously on Go goroutines and are serialized in sequence
order. They must promptly enqueue onto the platform queue and return. Never call
the engine inline from a callback: state delivery can hold the engine's lock.
Keep the listener alive and make the platform queue discard events from replaced
OS owners. Log callbacks carry diagnostic text, not telemetry payloads.

Each runtime attempt has a fresh libbox `CommandServer` service and exit channel.
The Go adapter subscribes to service status before launch, passes the engine's
generated configuration bytes directly to `StartOrReloadService`, and forwards
fatal/unexpected stop/reload events. It does not start a gRPC listener. Startup
returns at launch; connectcore's probes retain readiness ownership. Failed starts
close any partially created instance, including libbox's FATAL state, where
`CloseService` itself refuses cleanup. If `Box.Start` already closed the failed
instance, the adapter accepts `os.ErrClosed` as completed teardown and preserves
the startup error. Other close failures still keep the runtime unavailable.

Each `Done` reports once and closes. Stop waits for actual cleanup. An in-process
Go call cannot be forcibly killed safely: a blocked native startup or close can
exceed the stop grace. The binding then reports incomplete teardown and refuses
a second service until cleanup finishes; a failed close keeps the runtime
unavailable. The platform must retain its TUN owner until cleanup completes or
terminate the process through its OS lifecycle. A process crash/jetsam cannot
deliver an in-process callback. Real-device cancellation remains a B2/B3 gate.

## A4 vectors and test instrumentation

```sh
cd android/punchbridge
go test -race ./...
cd ../..
python3 scripts/test-engine-vectors.py -race -v
```

The latter is part of native binding CI. It runs all seven vendored A4 scenarios
through `newOpenRungEngine`, the public lifecycle methods, serialized callback
JSON, the binding's actual `TunnelRuntime`, and a local telemetry collector.
Only the libbox service/network outcomes are simulated. Whole projected status,
notice, and telemetry streams must equal the upstream vector expectations.

connectcore v0.6.0 exposes its deterministic network/probe seams only to its own
package tests. The runner copies that exact tagged module to a temporary test
workspace and changes only those existing identifiers' visibility. It does not
change engine logic, modify the module cache, regenerate expectations, or ship
test hooks in either release artifact. Kotlin runs the same seven scenarios
through JNI and EngineEventDispatcher using `scripts/test-android-engine-vectors.py`;
its isolated test AAR and application ID cannot be used in a release build. The script rejects a different tag or local
replacement until the adapter is reviewed. This is engine-contract validation;
shipping-native parity remains separately reviewed. Kotlin is local in
`testdata/contract/pin.json`; Swift remains pending until B3.

Both release scripts also run the concrete graft's libbox launch-failure and
constructor tests under Go's race detector, then verify generated ABI symbols.
The launch tests cover invalid JSON and repeated OS TUN refusals after instance
creation, followed by a successful start and stop on the same runtime.
Android's `EngineBindingAbiTest` checks the rebuilt AAR signatures without loading
Android native code in the host JVM. The Apple link smoke calls both constructors
and references every lifecycle method against the device and simulator archives.

## Memory evidence — 2026-09-05

Go 1.26.4, macOS arm64, app 0.3.8, connectcore v0.5.0. After GC, 1,000 retained
idle engines added 974,448 / 982,648 / 985,104 bytes of Go heap in three samples:
approximately **974–985 bytes per engine**, with **zero additional goroutines**.
Run without the race detector:

```sh
cd android/punchbridge
go test -run TestOpenRungEngineLoadedMemory -count=3 -v
```

The actual generated iOS simulator framework was also measured in three fresh
processes on iPhone 17 Pro / iOS 26.5 / arm64. `LibboxGoVersion` warms the existing
Go runtime before sampling `TASK_VM_INFO.phys_footprint`. The first bound idle
engine added **98,304 / 131,072 / 131,072 bytes (96–128 KiB)**. Retaining 1,000
native engine handles added 3,997,720 / 4,210,712 / 4,210,712 bytes total, including
Objective-C/gomobile handle storage and allocator overhead. Source:
`ios/scripts/libbox-engine-memory.m`.

To reproduce, build the Apple framework, compile the measurement source with the
same simulator clang/link flags as `libbox-broker-link-smoke.m`, then use
`xcrun simctl spawn <booted-device> <measurement-executable>`. No engine Start,
platform callback, tunnel, directory fetch, or telemetry session runs here.

These are idle incremental measurements, not a physical-device VPN footprint or
an iOS memory-budget pass. B3 must measure the running engine, directory cache,
libbox, network changes, and teardown against the maintainer's agreed limit.

## Resolved divergences

- The pin crosses connectcore's earlier explicit UDP/443 rejection fix. Updated
  shared config goldens now reject tunneled QUIC after every split-tunnel bypass,
  with `no_drop: true`; probe route pins are TCP-only. This affects the existing
  native callers of the shared config builder in B1 as well as future engines.
- The mobile outbox delegates to A3's shared implementation. Its public API,
  cancelable uploads, backlog migration, and durability tests remain. Shared
  queue-policy internals are tested upstream; their two white-box duplicates were
  removed here. The shared queue also bounds requests by encoded byte size and
  discards individually unsendable oversized events, an A3 behavior change.
- An in-process runtime reports a teardown deadline failure and prohibits
  overlapping runs instead of terminating a subprocess. The native owner must
  handle that error; B2/B3 must test the OS behavior on devices.

## Validation and cutover scope

Passed locally: TypeScript, 25 Jest suites / 300 tests, the standalone Go race
suite, all seven A4 scenarios under the race detector, both release builds and
their concrete libbox race tests, both Apple ABI links, 227 Android unit tests
against the rebuilt AAR, and 167 iOS unit tests with Thread Sanitizer.

Historical B1 scope: B1 passed engine-generated configs through unchanged. v0.5.0's orchestrator
still selects its default config/probe shapes; its engine API does not yet expose
all inputs accepted by the separate mobile config builder. B2/B3 must wire the
mobile DoH/split-tunnel/protected-bridge shape and platform TUN readiness before
cutover, preserve the existing install identity/outbox migration, translate relay
metadata into RN state, and arrange OS service recreation, data-plane pause,
traffic accounting, and memory enforcement. This PR does not claim real-device
VPN validation, native-parity acceptance, or completion of either cutover.

Android B2 treats an incomplete runtime teardown as a process-fatal condition.
It detaches network/event callbacks, publishes failure, stops the foreground
service, and terminates the process so the OS closes every duplicated TUN fd.
No subsequent command may start another run while termination is pending.
