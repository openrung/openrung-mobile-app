# ADR-003 B2: Android connectcore cutover

Status: in progress, based on mobile main `730f7b5` (B1, PR #111). Android still
runs the shipping orchestrator while the prerequisite API work is resolved.
There is no runtime engine selector. This branch is not cutover acceptance.

## Implemented preparation

- `OpenRungLibboxPlatform.kt` separates Android TUN creation, socket protection,
  connection ownership, and interface enumeration from `ProxyEngine.kt`.
  The existing service uses the extracted implementation without a behavior change.
- `EngineEventDispatcher.kt` implements the generated `OpenRungEngineListener`.
  It copies callbacks onto an asynchronous service queue, decodes B1 envelopes
  there, orders deliveries by sequence, and discards work queued for a retired
  service owner. Each attachment has a new identity even if its receiver is reused.
  It is ready for the new service host; the shipping service does not use it yet.
- JVM tests cover trampoline delivery, service replacement, rapid reconnect,
  duplicates/reordering, malformed envelopes, and stale diagnostic suppression.

Before replacing an event receiver, the future host must join the old engine's
Stop. Queue ownership cannot identify a callback from an old run that the host
has left alive. The process-wide engine and outbox remain reusable; owner
replacement must not construct a second engine over the same persistent store.

## Prerequisite API gaps

Reviewed the pinned `connectcore/v0.5.0` and latest available tag
`connectcore/v0.5.1`. The latter adds DNS port-53 hijacking and probe hardening;
it does not add the host APIs below. Production grafts must keep consuming a
published tag; exposing private test hooks or rewriting engine logic during a
release build is not an acceptable cutover mechanism.

| Shipping Android expectation and source | Current engine restriction | Required shared seam / acceptance |
| --- | --- | --- |
| Mobile DoH chain, probe pins, per-app and country bypass, Android TUN addresses, warning-level release logs: `SingBoxConfiguration.bindingInputJson`, `OpenRungVpnService.currentSplitTunnelRules` | `Engine.candidateConfigInput` fills only mode, relay and MTU. The richer builder inputs are unavailable through Engine. | Per-candidate mobile config input from the host, used by the existing shared builder for direct, punch and WSS. Re-read effective persisted split settings on recovery; mobile golden configs must match. |
| Config/permission preflight precedes remote reachability and ticket eligibility: `OpenRungVpnService.ensureLocalTunnelPreconditions` | Candidate config construction occurs in `startCandidate`, after direct reachability. | Host validation before remote failure classification, retaining local-error staging. Test that an invalid local config cannot mint a WSS ticket. |
| Android owns `Builder.establish` and verifies the newly established VPN path: `OpenRungLibboxPlatform.openTun`, `TunnelStartupGuard`, `TunnelPathProbe` | `tunnelReady`, `probeTunnel`, and `healthProbe` are private engine test seams. Default readiness and probe shape are fixed. | Public per-run readiness/path hooks or shared mobile implementations, with explicit proof that CONNECTED cannot result from a physical-network response. Preserve the fresh DNS + pinned HTTPS check and failure stages. |
| Stable install UUID and RN identity: `ClientIdentity`, `TelemetryManager.beginSession`, `OpenRungVpnModule.getIdentity` | `Engine.newManager` and directory identity both resolve the desktop-style filesystem ClientID. Only session ID is publicly readable. | Inject the existing native install ID before discovery and session creation. No global HOME/XDG mutation. All requests, stored events, and RN identity must agree across an upgrade/restart. |
| Existing durable backlog, reduced per-app counts, cumulative bytes, native metadata: `TelemetryManager`, `ApplicationConnectionAggregator` | Engine owns a private manager and a fixed-name outbox. It cannot accept an existing outbox/manager, record native app counts, or attach the manager's public traffic hook. | Explicit single-owner store/telemetry seam; migrate backlog without dropping its only durable copy; retain flow reduction, final traffic, and deadline cancellation. Stamp engine identity plus app version and platform on engine sessions. |
| Relay name/class and pinned recents: `OpenRungStatusStore`, `RecentNode` | `State` lacks relay ID/name/class; `ActiveConnectionInfo` exists but cannot be queried inside a synchronous locked callback. | Carry coherent relay/session detail across the binding, or define a versioned snapshot read on the native queue. Test switch/recovery interleavings so old metadata cannot accompany a successor's status. |

The upstream prerequisite must retain desktop defaults, bump connectcore VERSION,
run desktop/TUI tests, and publish a tag before the mobile PR can pin it. Once the
surface is available, B2 must finish the service host, replace the native ladder,
remove superseded Android policies/probes, and update `docs/CONTRACT.md`'s inventory.

## Independent parity evidence and remaining gates

The shipping source at mobile main `730f7b5` is the independent expectation
baseline; A4 vectors remain the engine sequence contract, not a substitute for
mobile parity. Keep the seven original scenarios unchanged. Kotlin must run them
against the bound engine before moving its entry in `testdata/contract/pin.json`
from pending to local; a JVM replay of expected JSON alone does not qualify.

Device evidence is still required for stop during start, rapid disconnect and
reconnect, rejected socket protection, Wi-Fi/cellular changes, pause/resume across
a changed epoch, sleep/wake, service restart, and pending telemetry on restart.
No Android device was attached during initial B2 preparation. No device or native
vector acceptance is claimed. Track C promotion remains separate.

## Resolved divergences

None in this preparation: the shipping service retains its behavior. Any
intentional differences in the eventual cutover must be reviewed and recorded
here and in the PR description before deleting the native implementation.
