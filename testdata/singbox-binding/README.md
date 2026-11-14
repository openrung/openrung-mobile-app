# sing-box binding fixtures

One `<scenario>.input.json` per platform scenario — the `OpenRungBuildSingBoxConfig` binding
input for that scenario — and one frozen
`<scenario>.golden.json` holding the bound builder's output for it.

The three suites compose into the platform emission expectations running end-to-end against
the shared Go builder (`connectcore/client`, pinned in `android/punchbridge/go.mod`), without
the JVM or the pod-free XCTest bundle loading the gomobile engine:

- `android/punchbridge/singbox_binding_test.go` is the only writer of the goldens and pins
  input → config through the real binding entry point. Regenerate deliberately with
  `UPDATE_SINGBOX_BINDING_GOLDEN=1 go test -run TestOpenRungBuildSingBoxConfigGolden .`
  from `android/punchbridge`.
- `SingBoxConfigurationBindingInputTest(.kt)` / `SingBoxConfigurationBindingInputTests` (Swift)
  pin the engine settings each platform hands connectcore against the inputs, minus the
  `relay` and bridge fields connectcore supplies itself.
- The platform structural suites (`SingBoxConfigurationDnsTest`, `SingBoxConfigurationSplitTunnelTest`,
  `SingBoxConfigurationPunchTest`, `DnsConfigurationTests`, `SplitTunnelConfigurationTests`, …)
  assert their emission expectations against the goldens.

The `relay` object in every input carries the broker's canonical wire names and one shared
test identity; scenario axes are the platform (`route_find_process` and `excluded_packages`
are Android-only), an optional loopback bridge, and the split-tunnel variants. All inputs use
the release log level ("warn"); the debug→"info" mapping is pinned separately by the
settings suites.
