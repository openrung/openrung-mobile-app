package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/openrung/openrung/brokerapi"
	"github.com/openrung/openrung/connectcore"
	"github.com/openrung/openrung/punchcore"
	"github.com/sagernet/sing-box/experimental/libbox/internal/openrungpunch"
)

// OpenRungEngineListener receives versioned JSON envelopes: state, notice, or
// log. Calls are synchronous on Go goroutines, may be concurrent, and must be
// fast. Like libbox's PlatformInterface, implementations must trampoline onto
// their platform queue and MUST NOT call back into the engine inline. Sequence
// numbers order concurrent deliveries. Keep the listener alive for the engine's
// lifetime and discard queued callbacks from a replaced platform owner.
type OpenRungEngineListener interface {
	OnEvent(eventJSON string)
}

// OpenRungEngine owns one reusable orchestrator. Start dispatches a connect;
// completion arrives at the listener. Disconnect requests a user stop; Stop
// joins teardown on the platform's IO queue. Stop bounds the terminal telemetry
// flush, not the entire shutdown, exactly as connectcore.Shutdown does. Reuse
// this handle across sessions: connectcore retains its durable outbox lock for
// the process lifetime. Neither pause nor a network callback starts a session.
type OpenRungEngine interface {
	Start(brokerURL, country, relayID string) error
	Disconnect() error
	Stop(flushBudgetMillis int64) error
	Pause()
	Resume()
	NetworkChanged(up bool, fingerprint, dnsServersJSON string) error
	StateJSON() string
	TeardownComplete() bool
}

// Construction is deliberately separate from connect arguments. The native
// constructors in engine_libbox.go supply the platform identity and runtime;
// JSON cannot select an unprotected Android path or a subprocess runtime.
type openRungEngineConfig struct {
	Mode               string `json:"mode"`
	MTU                int    `json:"mtu"`
	TelemetryDirectory string `json:"telemetry_directory"`
	PunchEnabled       *bool  `json:"punch_enabled"`
	PunchURL           string `json:"punch_url"`
}

type openRungEngine struct {
	networkDNS func([]string)
	engine     *connectcore.Engine
	runtime    *openRungEngineRuntime
	// Orders whole lifecycle calls, including Start versus Stop. The engine
	// has its own connect lock; this lock also orders Pause/Resume with them.
	mu sync.Mutex
}

func newOpenRungEngine(configJSON string, platform brokerapi.Platform,
	protector OpenRungWSSProtector, listener OpenRungEngineListener,
	runtime *openRungEngineRuntime, allowUnprotected bool,
) (*openRungEngine, error) {
	if strings.TrimSpace(configJSON) == "null" {
		return nil, errors.New("engine config must be an object")
	}
	var cfg openRungEngineConfig
	decoder := json.NewDecoder(strings.NewReader(configJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("engine config: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("trailing engine config data")
	}
	if runtime == nil || listener == nil {
		return nil, errors.New("engine runtime and listener are required")
	}
	if !allowUnprotected && protector == nil {
		return nil, errors.New("VPN socket protector is required")
	}
	if cfg.Mode != "" && cfg.Mode != "tun" && cfg.Mode != "proxy" {
		return nil, errors.New("engine mode must be tun or proxy")
	}
	if cfg.MTU < 0 || cfg.MTU > 65535 {
		return nil, errors.New("invalid engine MTU")
	}
	engine := connectcore.New()
	engine.Platform = platform
	engine.Sink = &openRungEngineSink{listener: listener}
	engine.TunnelRuntime = runtime
	engine.TunnelMTU = cfg.MTU
	if engine.TunnelMTU == 0 {
		engine.TunnelMTU = 1400
	}
	engine.TelemetryOutboxDirectory = cfg.TelemetryDirectory
	engine.PunchURL = cfg.PunchURL
	if cfg.PunchEnabled != nil {
		engine.PunchEnabled = *cfg.PunchEnabled
	}
	if protector != nil {
		engine.SocketProtector = protectedWSSSocket{protector: protector}
	}
	// Always wire the establisher, even when punching is disabled in settings.
	engine.PunchEstablisher = openRungEnginePunchEstablisher(protector, allowUnprotected, dialOpenRungPunch)
	engine.Elevation = openRungMobileElevation{}
	if cfg.Mode != "proxy" {
		_ = engine.SetMode(connectcore.ModeTUN)
	}
	engine.Start()
	return &openRungEngine{engine: engine, runtime: runtime}, nil
}

// OS consent and TUN ownership remain in VpnService/NEPacketTunnelProvider;
// construction happens only inside that owner after its consent step.
type openRungMobileElevation struct{}

func (openRungMobileElevation) Elevate(ctx context.Context) error { return ctx.Err() }

func (e *openRungEngine) Start(brokerURL, country, relayID string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.engine.Connect(brokerURL, country, relayID)
}
func (e *openRungEngine) Disconnect() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.engine.Disconnect()
}
func (e *openRungEngine) Stop(flushBudgetMillis int64) error {
	if flushBudgetMillis < 0 || flushBudgetMillis > int64(time.Hour/time.Millisecond) {
		return errors.New("invalid engine flush budget")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	err := e.engine.Shutdown(time.Duration(flushBudgetMillis) * time.Millisecond)
	// connectcore's candidate cleanup intentionally discards TunnelRun.Stop
	// errors. Mobile must still tell its OS owner when a TUN failed to close.
	return errors.Join(err, e.runtime.shutdownError())
}
func (e *openRungEngine) Pause()  { e.mu.Lock(); defer e.mu.Unlock(); e.engine.Pause() }
func (e *openRungEngine) Resume() { e.mu.Lock(); defer e.mu.Unlock(); e.engine.Resume() }
func (e *openRungEngine) StateJSON() string {
	data, _ := json.Marshal(e.engine.State())
	return string(data)
}
func (e *openRungEngine) NetworkChanged(up bool, fingerprint, dnsServersJSON string) error {
	var servers []string
	if err := json.Unmarshal([]byte(dnsServersJSON), &servers); err != nil {
		return fmt.Errorf("network DNS servers: %w", err)
	}
	for _, server := range servers {
		if _, err := netip.ParseAddr(server); err != nil {
			return errors.New("network DNS servers must be IP literals")
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.engine.SetDNSServers(servers)
	if e.networkDNS != nil {
		e.networkDNS(servers)
	}
	e.engine.UpdateNetworkState(connectcore.NetworkState{Up: up, Fingerprint: fingerprint})
	return nil
}

type openRungEngineSink struct {
	mu       sync.Mutex
	sequence uint64
	listener OpenRungEngineListener
}

func (s *openRungEngineSink) emit(kind string, payload any) {
	// Serialize the callback too: delivery order then agrees with sequence.
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sequence++
	data, err := json.Marshal(struct {
		Version  int    `json:"version"`
		Sequence uint64 `json:"sequence"`
		Kind     string `json:"kind"`
		Payload  any    `json:"payload"`
	}{1, s.sequence, kind, payload})
	if err == nil {
		s.listener.OnEvent(string(data))
	}
}
func (s *openRungEngineSink) StateChanged(state connectcore.State) { s.emit("state", state) }
func (s *openRungEngineSink) Log(entry connectcore.LogEntry)       { s.emit("log", entry) }
func (s *openRungEngineSink) Notice(notice connectcore.Notice)     { s.emit("notice", notice) }

func openRungEnginePunchEstablisher(protector OpenRungWSSProtector, allowUnprotected bool, dial openRungPunchDialer) connectcore.PunchEstablisher {
	return func(ctx context.Context, hub punchcore.HubClient, relayID string) (*connectcore.PunchPath, punchcore.PunchResult, error) {
		if !allowUnprotected && protector == nil {
			return nil, punchcore.PunchResult{Reason: "protect"}, errors.New("VPN socket protector is required")
		}
		d := &openrungpunch.Dialer{Hub: hub, RelayID: relayID, AllowUnprotectedSocket: allowUnprotected}
		if protector != nil {
			d.ProtectSocket = func(fd int64) bool { return (protectedWSSSocket{protector: protector}).Protect(int32(fd)) }
		}
		est, result, err := dial(ctx, d)
		if err != nil || est == nil || est.Bridge == nil {
			if est != nil {
				_ = est.Close()
			}
			if err == nil {
				err = errors.New("punch returned no bridge")
				result.Reason = "bridge"
			}
			return nil, result, err
		}
		if err = ctx.Err(); err != nil {
			_ = est.Close()
			return nil, punchcore.PunchResult{Reason: "cancelled"}, err
		}
		return &connectcore.PunchPath{BridgeHost: est.BridgeHost, BridgePort: est.BridgePort,
			PeerIP: est.PeerIP, SessionID: est.SessionID, NATClass: est.NATClass,
			Bridge: openRungEnginePunchBridge{est}}, result, nil
	}
}

type openRungEnginePunchBridge struct{ *openrungpunch.Establishment }

func (b openRungEnginePunchBridge) Serve(ctx context.Context) error { return b.Bridge.Serve(ctx) }

func (e *openRungEngine) TeardownComplete() bool { return e.runtime.shutdownError() == nil }
