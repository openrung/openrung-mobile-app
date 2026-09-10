//go:build openrung_contract

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/openrung/openrung/brokerapi"
	"github.com/openrung/openrung/connectcore"
	"github.com/openrung/openrung/connectcore/discovery"
	"github.com/openrung/openrung/punchcore"
	"github.com/openrung/openrung/wsscore"
)

// Test-only network/runtime seams. Never included in release artifacts.
// Both Go and Kotlin drive the real binding and tagged connectcore state machine.
type engineSequence struct {
	ID        string `json:"id"`
	Directory []struct {
		ID, City, Country string
		CountryCode       string   `json:"country_code"`
		Fronts            []string `json:"wss_fronts"`
		PunchCapable      bool     `json:"punch_capable"`
	}
	Script struct {
		Dials         []struct{ Relay, Cause string }
		Punch         *struct{ Reason string }
		HoldReadiness bool `json:"hold_readiness"`
		TelemetryHeld bool `json:"telemetry_held_until_session_end"`
	}
	Steps []struct {
		Do, Status, Kind, Fingerprint, Cause string
		Count                                int
		Up                                   bool
		FlushBudget                          int64 `json:"flush_budget_ms"`
	}
	Expect engineSequenceOutput
}
type engineSequenceOutput struct {
	Statuses []string         `json:"statuses"`
	Notices  []map[string]any `json:"notices"`
	Events   []map[string]any `json:"events"`
}
type sequenceRecorder struct {
	mu       sync.Mutex
	output   engineSequenceOutput
	seen     map[string]bool
	held     bool
	listener OpenRungEngineListener
}

func newSequenceRecorder() *sequenceRecorder {
	return &sequenceRecorder{output: engineSequenceOutput{Statuses: []string{}, Notices: []map[string]any{}, Events: []map[string]any{}}, seen: map[string]bool{}}
}
func (r *sequenceRecorder) OnEvent(raw string) {
	if r.listener != nil {
		r.listener.OnEvent(raw)
	}
	var e struct {
		Kind    string
		Payload json.RawMessage
	}
	if json.Unmarshal([]byte(raw), &e) != nil {
		panic("invalid engine callback JSON")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	switch e.Kind {
	case "state":
		var s connectcore.State
		_ = json.Unmarshal(e.Payload, &s)
		statuses := r.output.Statuses
		if len(statuses) == 0 || statuses[len(statuses)-1] != string(s.Status) {
			r.output.Statuses = append(statuses, string(s.Status))
		}
	case "notice":
		var n connectcore.Notice
		_ = json.Unmarshal(e.Payload, &n)
		m := map[string]any{"kind": string(n.Kind)}
		for k, v := range map[string]string{"relay_id": n.RelayID, "from_relay_id": n.FromRelayID, "front_id": n.FrontID} {
			if v != "" {
				m[k] = v
			}
		}
		if n.Failures != 0 {
			m["failures"] = float64(n.Failures)
		}
		if n.Threshold != 0 {
			m["threshold"] = float64(n.Threshold)
		}
		r.output.Notices = append(r.output.Notices, m)
	}
}
func (r *sequenceRecorder) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	var batch struct{ Events []brokerapi.TelemetryEvent }
	if json.NewDecoder(req.Body).Decode(&batch) != nil {
		w.WriteHeader(503)
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.held {
		for _, e := range batch.Events {
			if e.Event == "connection_ended" {
				r.held = false
			}
		}
		if r.held {
			w.WriteHeader(503)
			return
		}
	}
	for _, e := range batch.Events {
		if r.seen[e.EventID] {
			continue
		}
		r.seen[e.EventID] = true
		if e.Event == "session_heartbeat" {
			continue
		}
		m := map[string]any{"event": e.Event}
		if e.RelayID != "" {
			m["relay_id"] = e.RelayID
		}
		attrs := map[string]any{}
		for _, k := range []string{"transport", "from_transport", "to_transport", "front_id", "trigger", "reason", "nat_class", "from_relay_id", "failure_reason", "failure_stage"} {
			if v, ok := e.Attributes[k]; ok {
				attrs[k] = v
			}
		}
		if len(attrs) > 0 {
			m["attributes"] = attrs
		}
		r.output.Events = append(r.output.Events, m)
	}
	w.WriteHeader(204)
}
func (r *sequenceRecorder) snapshot() engineSequenceOutput {
	r.mu.Lock()
	defer r.mu.Unlock()
	raw, _ := json.Marshal(r.output)
	var copy engineSequenceOutput
	_ = json.Unmarshal(raw, &copy)
	return copy
}

type sequenceWSSBridge struct {
	stop chan struct{}
	once sync.Once
}

func (*sequenceWSSBridge) Endpoint() (string, int) { return "127.0.0.1", 43123 }
func (b *sequenceWSSBridge) Serve(ctx context.Context) error {
	select {
	case <-ctx.Done():
	case <-b.stop:
	}
	return nil
}
func (*sequenceWSSBridge) SessionEnd() wsscore.SessionEnd { return wsscore.SessionEnd(0) }
func (b *sequenceWSSBridge) Close() error                 { b.once.Do(func() { close(b.stop) }); return nil }

// OpenRungContractScenario owns one isolated scripted environment, not a fake engine.
// Exported solely by scripts/test-android-engine-vectors.py into its test AAR.
type OpenRungContractScenario struct {
	engine   *openRungEngine
	broker   *httptest.Server
	recorder *sequenceRecorder
	held     chan struct{}
	release  chan struct{}
	once     sync.Once
	crash    func() error
}

func NewOpenRungContractScenario(raw, directory string, listener OpenRungEngineListener) (*OpenRungContractScenario, error) {
	var sc engineSequence
	if err := json.Unmarshal([]byte(raw), &sc); err != nil {
		return nil, err
	}
	// Test processes run scenarios serially. No shipping code changes process env.
	for _, key := range []string{"HOME", "XDG_CONFIG_HOME", "AppData"} {
		if err := os.Setenv(key, directory); err != nil {
			return nil, err
		}
	}
	r := newSequenceRecorder()
	r.held = sc.Script.TelemetryHeld
	r.listener = listener
	broker := httptest.NewServer(r)

	var activeMu sync.Mutex
	var active *sequenceService
	rt := &openRungEngineRuntime{newService: func() (openRungEngineService, error) {
		s := &sequenceService{exit: make(chan error, 1), startFn: func(cfg string) error {
			if !json.Valid([]byte(cfg)) {
				return errors.New("invalid runtime config")
			}
			return nil
		}}
		activeMu.Lock()
		active = s
		activeMu.Unlock()
		return s, nil
	}}
	e, err := newOpenRungEngine(`{"mode":"proxy","punch_enabled":false}`, brokerapi.PlatformIOS, nil, r, rt, true)
	if err != nil {
		broker.Close()
		return nil, err
	}

	core := e.engine
	core.OpenRungTestHealthTick = time.Hour
	core.OpenRungTestHeartbeatTick = time.Hour
	core.OpenRungTestLookupGeo = func(context.Context, *http.Client) map[string]string { return nil }
	core.OpenRungTestCheckNetworkAlive = func(context.Context, []string) bool { return true }
	core.OpenRungTestProbeTunnel = func(context.Context, int) (int64, error) { return 2, nil }
	core.OpenRungTestHealthProbe = func(context.Context, int) error { return nil }
	core.OpenRungTestTunnelReady = func(context.Context, int) error { return nil }
	relays := []brokerapi.RelayDescriptor{}
	causes := map[string]error{}
	fronts := map[string]brokerapi.RelayWSSFront{}
	for i, row := range sc.Directory {
		host := fmt.Sprintf("127.0.0.%d", 10+i)
		relay := brokerapi.RelayDescriptor{ID: row.ID, PublicHost: host, PublicPort: 443, Protocol: brokerapi.ProtocolVLESSRealityVision, ClientID: "uuid", RealityPublicKey: "pk", ShortID: "sid", ServerName: "sni", Flow: brokerapi.FlowVision, ExitMode: brokerapi.ExitModeDirect, ExpiresAt: time.Now().Add(time.Hour), PunchCapable: row.PunchCapable, RelayGeoLocation: brokerapi.RelayGeoLocation{City: row.City, Country: row.Country, CountryCode: row.CountryCode, Latitude: 1, Longitude: 2}}
		for _, id := range row.Fronts {
			f := brokerapi.RelayWSSFront{ID: id, URL: "wss://a.cdn.example/api/v1/wss-bridge", ProtocolVersion: 1}
			fronts[id] = f
			relay.WSSFronts = append(relay.WSSFronts, f)
			relay.NodeClass = brokerapi.NodeClassFoundation
			relay.Transport = brokerapi.TransportDirect
		}
		relays = append(relays, relay)
		for _, d := range sc.Script.Dials {
			if d.Relay == row.ID {
				if d.Cause != "connection_refused" {
					return nil, errors.New("unknown dial cause")
				}
				causes[host] = syscall.ECONNREFUSED
			}
		}
	}
	core.OpenRungTestFetchRelays = func(_ context.Context, url string, _ int, _, _ string) (discovery.Fetch, error) {
		return discovery.Fetch{BrokerURL: url, Response: brokerapi.RelayListResponse{Relays: relays, Count: len(relays), ServerTime: time.Now()}}, nil
	}
	core.OpenRungTestDialRelay = func(_ context.Context, host string, _ int) (int64, error) { return 1, causes[host] }
	core.OpenRungTestRequestWSSTicket = func(_ context.Context, _ string, req brokerapi.WSSTicketRequest, _, _ string) (brokerapi.WSSTicketResponse, error) {
		front := fronts[req.FrontID]
		return brokerapi.WSSTicketResponse{Ticket: "scripted-ticket", URL: front.URL, ExpiresAt: time.Now().Add(time.Minute)}, nil
	}
	core.OpenRungTestDialWSS = func(context.Context, string, string) (connectcore.OpenRungTestWssBridge, error) {
		return &sequenceWSSBridge{stop: make(chan struct{})}, nil
	}
	if sc.Script.Punch != nil {
		core.PunchEnabled = true
		core.PunchEstablisher = func(context.Context, punchcore.HubClient, string) (*connectcore.PunchPath, punchcore.PunchResult, error) {
			return nil, punchcore.PunchResult{Reason: sc.Script.Punch.Reason}, errors.New("scripted punch failure")
		}
	}
	held, release := make(chan struct{}, 1), make(chan struct{})
	if sc.Script.HoldReadiness {
		core.OpenRungTestTunnelReady = func(ctx context.Context, _ int) error {
			select {
			case <-release:
				return nil
			default:
			}
			select {
			case held <- struct{}{}:
			default:
			}
			select {
			case <-release:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}

	return &OpenRungContractScenario{engine: e, broker: broker, recorder: r, held: held, release: release, crash: func() error {
		activeMu.Lock()
		defer activeMu.Unlock()
		if active == nil {
			return errors.New("no live tunnel")
		}
		active.exit <- errors.New("scripted unclassified failure")
		return nil
	}}, nil
}
func (s *OpenRungContractScenario) Engine() OpenRungEngine { return s.engine }
func (s *OpenRungContractScenario) BrokerURL() string      { return s.broker.URL }
func (s *OpenRungContractScenario) EventsJSON() string {
	b, _ := json.Marshal(s.recorder.snapshot().Events)
	return string(b)
}
func (s *OpenRungContractScenario) CrashTunnel() error { return s.crash() }
func (s *OpenRungContractScenario) AwaitReadyHold() error {
	select {
	case <-s.held:
		return nil
	case <-time.After(10 * time.Second):
		return errors.New("readiness never held")
	}
}
func (s *OpenRungContractScenario) ReleaseReady() { s.once.Do(func() { close(s.release) }) }
func (s *OpenRungContractScenario) Close() error {
	err := s.engine.Stop(1000)
	s.broker.Close()
	return err
}

type sequenceService struct {
	exit    chan error
	startFn func(string) error
}

func (s *sequenceService) start(config string) error { return s.startFn(config) }
func (s *sequenceService) close() error              { return nil }
func (s *sequenceService) done() <-chan error        { return s.exit }
