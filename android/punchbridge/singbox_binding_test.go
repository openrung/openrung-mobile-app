package libbox

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The sing-box binding fixtures: one .input.json per platform scenario (the
// binding input the Kotlin/Swift assembly must produce, pinned by the platform
// suites), and one frozen .golden.json holding the bound output. This test is
// the only writer of the goldens; regenerate deliberately with:
//
//	UPDATE_SINGBOX_BINDING_GOLDEN=1 go test -run TestOpenRungBuildSingBoxConfigGolden .
const singBoxBindingFixtureDir = "../../testdata/singbox-binding"

func singBoxScenarioNames(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir(singBoxBindingFixtureDir)
	if err != nil {
		t.Fatalf("reading fixture directory: %v", err)
	}
	var names []string
	for _, entry := range entries {
		if name, ok := strings.CutSuffix(entry.Name(), ".input.json"); ok {
			names = append(names, name)
		}
	}
	if len(names) < 10 {
		t.Fatalf("only %d scenarios found; the fixture directory changed shape", len(names))
	}
	return names
}

func readSingBoxFixture(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(singBoxBindingFixtureDir, name))
	if err != nil {
		t.Fatalf("reading %s: %v", name, err)
	}
	return string(raw)
}

// TestOpenRungBuildSingBoxConfigGolden composes with the Kotlin and Swift
// suites: they pin platform state → fixture input, this pins fixture input →
// emitted config through the real binding entry point, and the platform
// structural suites re-run their emission assertions against the frozen
// goldens — so the existing platform expectations hold against the bound
// output without the JVM or a pod-free XCTest bundle loading the engine.
func TestOpenRungBuildSingBoxConfigGolden(t *testing.T) {
	for _, name := range singBoxScenarioNames(t) {
		t.Run(name, func(t *testing.T) {
			result := OpenRungBuildSingBoxConfig(readSingBoxFixture(t, name+".input.json"))
			if !result.Succeeded() {
				t.Fatalf("build failed: %s", result.ErrorText())
			}
			got := []byte(result.ConfigJSON())
			goldenPath := filepath.Join(singBoxBindingFixtureDir, name+".golden.json")
			if os.Getenv("UPDATE_SINGBOX_BINDING_GOLDEN") != "" {
				if err := os.WriteFile(goldenPath, got, 0o644); err != nil {
					t.Fatalf("update golden: %v", err)
				}
			}
			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden (run with UPDATE_SINGBOX_BINDING_GOLDEN=1 to create): %v", err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("config drifted from %s:\n--- want\n%s\n--- got\n%s", goldenPath, want, got)
			}
		})
	}
}

// TestOpenRungBuildSingBoxConfigEmptySplitRulesEmitTheNoSplitConfig pins the
// identity the platform suites rely on: all-empty split rules and no split
// rules at all emit byte-identical configs, on both platform shapes.
func TestOpenRungBuildSingBoxConfigEmptySplitRulesEmitTheNoSplitConfig(t *testing.T) {
	for _, platform := range []string{"android", "ios"} {
		baseline := readSingBoxFixture(t, platform+"-tun.golden.json")
		emptied := readSingBoxFixture(t, platform+"-split-empty.golden.json")
		if baseline != emptied {
			t.Fatalf("%s: all-empty split rules must emit the exact no-split configuration", platform)
		}
	}
}

// TestOpenRungBuildSingBoxConfigValidation: the mobile input contract this
// binding enforces on top of connectcore's own relay and split-tunnel
// validation. Every rejection carries an error and no config.
func TestOpenRungBuildSingBoxConfigValidation(t *testing.T) {
	valid := readSingBoxFixture(t, "android-tun.input.json")
	mutate := func(t *testing.T, change func(input map[string]any)) string {
		t.Helper()
		var input map[string]any
		if err := json.Unmarshal([]byte(valid), &input); err != nil {
			t.Fatalf("decode valid fixture: %v", err)
		}
		change(input)
		encoded, err := json.Marshal(input)
		if err != nil {
			t.Fatalf("encode mutated input: %v", err)
		}
		return string(encoded)
	}

	cases := map[string]string{
		"not JSON":      `not json`,
		"empty string":  ``,
		"trailing data": valid + " {}",
		"unknown field": mutate(t, func(input map[string]any) { input["dns_servers"] = []string{"9.9.9.9"} }),
		"missing relay": mutate(t, func(input map[string]any) { delete(input, "relay") }),
		"invalid relay protocol": mutate(t, func(input map[string]any) {
			input["relay"].(map[string]any)["protocol"] = "wireguard"
		}),
		"relay missing connection fields": mutate(t, func(input map[string]any) {
			delete(input["relay"].(map[string]any), "reality_public_key")
		}),
		"missing mtu":  mutate(t, func(input map[string]any) { delete(input, "mtu") }),
		"negative mtu": mutate(t, func(input map[string]any) { input["mtu"] = -1 }),
		"bridge host without port": mutate(t, func(input map[string]any) {
			input["bridge_host"] = "127.0.0.1"
		}),
		"bridge port without host": mutate(t, func(input map[string]any) {
			input["bridge_port"] = 54321
		}),
		"bridge port out of range": mutate(t, func(input map[string]any) {
			input["bridge_host"] = "127.0.0.1"
			input["bridge_port"] = 65536
		}),
		"missing log level": mutate(t, func(input map[string]any) { delete(input, "log_level") }),
		"missing probe suffixes": mutate(t, func(input map[string]any) {
			delete(input, "probe_domain_suffixes")
		}),
		"unknown split-tunnel country": mutate(t, func(input map[string]any) {
			input["split_tunnel"] = map[string]any{
				"bypass_countries":   []string{"us"},
				"rule_set_directory": "/rulesets",
			}
		}),
		"duplicate split-tunnel country": mutate(t, func(input map[string]any) {
			input["split_tunnel"] = map[string]any{
				"bypass_countries":   []string{"cn", "cn"},
				"rule_set_directory": "/rulesets",
			}
		}),
		"bypass country without a rule-set directory": mutate(t, func(input map[string]any) {
			input["split_tunnel"] = map[string]any{"bypass_countries": []string{"cn"}}
		}),
	}
	for name, input := range cases {
		result := OpenRungBuildSingBoxConfig(input)
		if result.Succeeded() {
			t.Errorf("%s: expected the build to be rejected", name)
			continue
		}
		if result.ErrorText() == "" {
			t.Errorf("%s: a rejection must carry an error text", name)
		}
		if result.ConfigJSON() != "" {
			t.Errorf("%s: a rejection must carry no config", name)
		}
	}
}
