//go:build openrung_contract

package libbox

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"
)

func sequenceAwait(t *testing.T, predicate func() bool) {
	t.Helper()
	deadline := time.After(10 * time.Second)
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for !predicate() {
		select {
		case <-deadline:
			t.Fatal("timed out awaiting scenario step")
		case <-tick.C:
		}
	}
}

func TestOpenRungEngineSequences(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/contract/event_sequence.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Version   int
		Scenarios []engineSequence
	}
	if err = json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	if vectors.Version != 1 || len(vectors.Scenarios) < 6 {
		t.Fatal("review changed vector contract")
	}
	for _, sc := range vectors.Scenarios {
		t.Run(sc.ID, func(t *testing.T) { runBoundEngineSequence(t, sc) })
	}
}
func runBoundEngineSequence(t *testing.T, sc engineSequence) {

	raw, _ := json.Marshal(sc)
	scenario, err := NewOpenRungContractScenario(string(raw), t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer scenario.Close()
	e, r := scenario.engine, scenario.recorder
	for i, step := range sc.Steps {
		t.Logf("step %d: %s", i+1, step.Do)
		switch step.Do {
		case "connect":
			err = e.Start(scenario.BrokerURL(), "", "")
		case "disconnect":
			err = e.Disconnect()
		case "shutdown":
			err = e.Stop(step.FlushBudget)
		case "network":
			err = e.NetworkChanged(step.Up, step.Fingerprint, `[]`)
		case "await_status":
			sequenceAwait(t, func() bool {
				n := 0
				for _, s := range r.snapshot().Statuses {
					if s == step.Status {
						n++
					}
				}
				return n >= max(step.Count, 1)
			})
		case "await_notice":
			sequenceAwait(t, func() bool {
				n := 0
				for _, s := range r.snapshot().Notices {
					if s["kind"] == step.Kind {
						n++
					}
				}
				return n >= max(step.Count, 1)
			})
		case "crash_tunnel":
			err = scenario.CrashTunnel()
		case "await_ready_hold":
			err = scenario.AwaitReadyHold()
		case "release_ready":
			scenario.ReleaseReady()
		default:
			t.Fatalf("unknown step %q", step.Do)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	// Shutdown joins terminal flush even when Disconnect only dispatched it.
	if err = e.Stop(1000); err != nil {
		t.Fatal(err)
	}
	got := r.snapshot()
	if !reflect.DeepEqual(got, sc.Expect) {
		a, _ := json.MarshalIndent(got, "", "  ")
		b, _ := json.MarshalIndent(sc.Expect, "", "  ")
		t.Fatalf("bound sequence differs\ngot: %s\nwant: %s", a, b)
	}
}
