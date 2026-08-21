package libbox

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/openrung/openrung/brokerapi"
	"github.com/openrung/openrung/connectcore/client"
)

// openRungSingBoxInput is one platform-described sing-box build request: the
// inputs SingBoxConfiguration.kt / SingBoxConfiguration.swift assemble, with
// every emission decision left to connectcore's shared builder
// (client.BuildSingBoxConfig — the superset that reproduces the mobile
// generators' output shape). The relay object uses the broker's canonical
// wire names, so it decodes straight into brokerapi.RelayDescriptor.
type openRungSingBoxInput struct {
	// Relay carries the connection identity fields of the selected relay
	// (public_host, public_port, protocol, flow, exit_mode, client_id,
	// reality_public_key, short_id, server_name).
	Relay json.RawMessage `json:"relay"`
	// TunnelIPv4Address / TunnelIPv6Address are the TUN addresses; empty keeps
	// connectcore's defaults, which equal the mobile constants.
	TunnelIPv4Address string `json:"tunnel_ipv4_address"`
	TunnelIPv6Address string `json:"tunnel_ipv6_address"`
	// MTU is required and must be positive: connectcore would default a zero
	// MTU to 1500, silently replacing mobile's deliberate 1400.
	MTU int `json:"mtu"`
	// BridgeHost and BridgePort redirect the VLESS outbound to a local punch or
	// WSS loopback adapter. Mobile bridges always own a platform-protected
	// outer socket (VpnService.protect / the provider's tunnel-exempt socket),
	// so an active bridge also suppresses every TUN route exclusion — a peer
	// /32 on a protected transport would leak unrelated apps' traffic.
	BridgeHost string `json:"bridge_host"`
	BridgePort int    `json:"bridge_port"`
	// LogLevel is required: "info" for debug builds, "warn" for release, and
	// an empty value is an assembly bug rather than a request for a default.
	LogLevel string `json:"log_level"`
	// RouteFindProcess emits route.find_process (Android; iOS leaves it off).
	RouteFindProcess bool `json:"route_find_process"`
	// ProbeDomainSuffixes are the platform's ProbeTargets, required so the
	// probe-priority DNS and route pins can never silently diverge from the
	// endpoints the platform actually probes.
	ProbeDomainSuffixes []string `json:"probe_domain_suffixes"`
	// SplitTunnel enables split tunneling when non-nil; connectcore validates
	// its countries and rule-set directory and emits a byte-identical no-split
	// config for all-empty rules.
	SplitTunnel *openRungSplitTunnelInput `json:"split_tunnel"`
}

type openRungSplitTunnelInput struct {
	BypassLAN        bool     `json:"bypass_lan"`
	BypassCountries  []string `json:"bypass_countries"`
	ExcludedPackages []string `json:"excluded_packages"`
	RuleSetDirectory string   `json:"rule_set_directory"`
}

// OpenRungSingBoxConfigResult is one build outcome: the emitted config JSON,
// or the validation/build error that rejected the input. The error text names
// input fields only — relay secrets are never interpolated into it.
type OpenRungSingBoxConfigResult struct {
	configJSON string
	errorText  string
}

func (r *OpenRungSingBoxConfigResult) Succeeded() bool {
	return r != nil && r.errorText == "" && r.configJSON != ""
}

func (r *OpenRungSingBoxConfigResult) ConfigJSON() string {
	if r == nil {
		return ""
	}
	return r.configJSON
}

func (r *OpenRungSingBoxConfigResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.errorText
}

// OpenRungBuildSingBoxConfig builds the sing-box configuration for one
// platform-assembled input (openRungSingBoxInput as JSON) through
// connectcore's shared builder, so both mobile platforms and the desktop/CLI
// clients emit the same shape from one implementation. The platforms keep
// only input assembly; validation of the assembled input happens here (the
// mobile-specific contract) and in connectcore (relay identity, split-tunnel
// countries).
func OpenRungBuildSingBoxConfig(inputJSON string) *OpenRungSingBoxConfigResult {
	input, err := decodeOpenRungSingBoxInput(inputJSON)
	if err != nil {
		return failedOpenRungSingBoxConfigResult(err)
	}
	builderInput, err := openRungSingBoxBuilderInput(input)
	if err != nil {
		return failedOpenRungSingBoxConfigResult(err)
	}
	configJSON, err := client.BuildSingBoxConfig(builderInput)
	if err != nil {
		return failedOpenRungSingBoxConfigResult(err)
	}
	return &OpenRungSingBoxConfigResult{configJSON: string(configJSON)}
}

func decodeOpenRungSingBoxInput(inputJSON string) (openRungSingBoxInput, error) {
	var input openRungSingBoxInput
	decoder := json.NewDecoder(strings.NewReader(inputJSON))
	// The adapters ship in the same bundle as this binding, so an unknown
	// field is drift, not forward compatibility. The relay sub-object is
	// decoded against brokerapi's canonical descriptor below instead.
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return openRungSingBoxInput{}, fmt.Errorf("invalid sing-box build input: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return openRungSingBoxInput{}, errors.New("trailing data after sing-box build input")
	}
	return input, nil
}

// openRungSingBoxBuilderInput validates the mobile input contract and maps it
// onto connectcore's builder input. The constants of the mobile shape — TUN
// inbound, DoH failover DNS, traffic accounting — are fixed here rather than
// assembled per call: no mobile build has ever varied them, and a platform
// that could would be re-deciding policy this binding exists to centralize.
func openRungSingBoxBuilderInput(input openRungSingBoxInput) (client.SingBoxConfigInput, error) {
	if len(input.Relay) == 0 {
		return client.SingBoxConfigInput{}, errors.New("sing-box build input has no relay")
	}
	var relay brokerapi.RelayDescriptor
	if err := json.Unmarshal(input.Relay, &relay); err != nil {
		return client.SingBoxConfigInput{}, fmt.Errorf("invalid relay in sing-box build input: %w", err)
	}
	if input.MTU <= 0 {
		// connectcore would default a zero MTU to 1500; mobile's 1400 is
		// deliberate, so an absent MTU is an assembly bug.
		return client.SingBoxConfigInput{}, errors.New("mtu must be positive")
	}
	hasBridgeHost := input.BridgeHost != ""
	hasBridgePort := input.BridgePort != 0
	if hasBridgeHost != hasBridgePort || (hasBridgePort && (input.BridgePort < 1 || input.BridgePort > 65535)) {
		// connectcore quietly ignores a partial bridge and dials the relay's
		// public endpoint; for mobile that would mask a broken punch/WSS
		// adapter as a direct connection.
		return client.SingBoxConfigInput{}, errors.New("loopback adapter requires a host and valid port")
	}
	if strings.TrimSpace(input.LogLevel) == "" {
		return client.SingBoxConfigInput{}, errors.New("sing-box build input has no log level")
	}
	if len(input.ProbeDomainSuffixes) == 0 {
		// connectcore would fall back to its own copy of the probe suffixes;
		// requiring the platform's keeps the DNS/route probe pins provably
		// aligned with the endpoints the platform actually probes.
		return client.SingBoxConfigInput{}, errors.New("sing-box build input has no probe domain suffixes")
	}

	builderInput := client.SingBoxConfigInput{
		Relay:               relay,
		TunnelIPv4Address:   input.TunnelIPv4Address,
		TunnelIPv6Address:   input.TunnelIPv6Address,
		MTU:                 input.MTU,
		BridgeHost:          input.BridgeHost,
		BridgePort:          input.BridgePort,
		LogLevel:            input.LogLevel,
		RouteFindProcess:    input.RouteFindProcess,
		ProbeDomainSuffixes: input.ProbeDomainSuffixes,
		// The mobile shape: full-device TUN, DoH failover DNS (TCP/53 gets no
		// replies under WSS relays), and clash_api traffic accounting feeding
		// the session byte counters.
		DNSShape: client.DNSShapeDoHFailover,
		ClashAPI: true,
		// Every mobile bridge owns a platform-protected outer socket; see
		// openRungSingBoxInput.BridgeHost.
		BridgeOwnsOuterSocket: hasBridgeHost,
	}
	if input.SplitTunnel != nil {
		builderInput.SplitTunnel = &client.SplitTunnelRules{
			BypassLAN:        input.SplitTunnel.BypassLAN,
			BypassCountries:  input.SplitTunnel.BypassCountries,
			ExcludedPackages: input.SplitTunnel.ExcludedPackages,
			RuleSetDirectory: input.SplitTunnel.RuleSetDirectory,
		}
	}
	return builderInput, nil
}

func failedOpenRungSingBoxConfigResult(err error) *OpenRungSingBoxConfigResult {
	return &OpenRungSingBoxConfigResult{errorText: err.Error()}
}
