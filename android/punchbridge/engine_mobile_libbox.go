//go:build openrung_libbox

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/openrung/openrung/brokerapi"
	"github.com/openrung/openrung/connectcore"
	"github.com/openrung/openrung/connectcore/clienttelemetry"
	"github.com/openrung/openrung/wsscore"
	"github.com/sagernet/sing-box/daemon"
	"google.golang.org/grpc/metadata"
)

// Host callbacks run on Go workers, never the engine event queue. They must not
// call Engine. Settings checks permission and returns a fresh immutable snapshot.
type OpenRungMobileHost interface {
	SettingsJSON() (string, error)
	AttributesJSON() string
	NewRun(telemetry *OpenRungRunTelemetry) (OpenRungMobileRun, error)
}

// One native owner per libbox attempt. Close cancels/joins operations and drains
// reduced flow counts before releasing its TUN fd. Platform never changes owners.
type OpenRungMobileRun interface {
	Platform() PlatformInterface
	WaitReady(operation *OpenRungEngineOperation) error
	VerifyPath(operation *OpenRungEngineOperation, phase string) string
	Close() error
}

// Native blocking operations poll cancellation and close their network sockets.
// The capability expires with the operation; retaining it cannot affect a successor.
type OpenRungEngineOperation struct{ ctx context.Context }

func (o *OpenRungEngineOperation) IsCancelled() bool {
	return o == nil || o.ctx == nil || o.ctx.Err() != nil
}

type OpenRungRunTelemetry struct{ reporter *connectcore.RunTelemetry }

func (r *OpenRungRunTelemetry) RecordApplicationConnections(packageName string, uid int32, count int64) bool {
	if r == nil || r.reporter == nil {
		return false
	}
	return r.reporter.RecordApplicationConnections(packageName, int(uid), count)
}

type openRungMobileConfig struct {
	InstallID       string            `json:"install_id"`
	AppVersion      string            `json:"app_version"`
	PlatformVersion string            `json:"platform_version"`
	Directory       string            `json:"telemetry_directory"`
	LegacyBatch     string            `json:"legacy_telemetry_batch"`
	CoordinatorPins map[string]string `json:"punch_coordinator_cert_sha256_by_host"`
}

// NewOpenRungMobileEngineForAndroid owns the existing native outbox filename.
// Construction must happen once per process, after retiring all legacy uploaders.
// Legacy decoding matches the shipping outbox: corrupt rows are discarded,
// while a durability failure rejects construction so the host retains its source.
func NewOpenRungMobileEngineForAndroid(configJSON string, protector OpenRungWSSProtector, host OpenRungMobileHost, listener OpenRungEngineListener) (OpenRungEngine, error) {
	if protector == nil {
		return nil, errors.New("VPN socket protector is required")
	}
	engine, err := newOpenRungMobileEngine(configJSON, brokerapi.PlatformAndroid, protector, host, listener)
	if err != nil {
		return nil, err
	}
	return engine, nil
}

// NewOpenRungMobileEngineForIOS is valid only inside the authorized packet tunnel
// extension. Provider-owned outer sockets bypass its own TUN; probes must use
// the provider's explicit through-tunnel APIs and attest that path separately.
func NewOpenRungMobileEngineForIOS(configJSON string, host OpenRungMobileHost, listener OpenRungEngineListener) (OpenRungEngine, error) {
	if iosConstructorRequiresSocketProtector() {
		return nil, errors.New("iOS mobile engine requires the iOS runtime")
	}
	engine, err := newOpenRungMobileEngine(configJSON, brokerapi.PlatformIOS, nil, host, listener)
	if err != nil {
		return nil, err
	}
	return engine, nil
}

func newOpenRungMobileEngine(configJSON string, platform brokerapi.Platform, protector OpenRungWSSProtector, host OpenRungMobileHost, listener OpenRungEngineListener) (*openRungEngine, error) {
	var cfg openRungMobileConfig
	if err := decodeOpenRungObject(configJSON, &cfg); err != nil {
		return nil, err
	}
	if host == nil || listener == nil || !clienttelemetry.ValidInstallID(cfg.InstallID) || cfg.Directory == "" || cfg.AppVersion == "" {
		return nil, errors.New("mobile host, listener, install UUID, version and outbox directory required")
	}
	var legacy []clienttelemetry.Event
	if cfg.LegacyBatch != "" {
		var rows []json.RawMessage
		if json.Unmarshal([]byte(cfg.LegacyBatch), &rows) == nil {
			for _, row := range rows {
				if event, ok := decodeOpenRungTelemetryEvent(string(row)); ok {
					legacy = append(legacy, event)
				}
			}
		}
	}
	protected := protectedWSSSocket{protector: protector}
	// Outbox uploads use exactly the same protected broker route as engine traffic.
	var dnsMu sync.RWMutex
	var dnsServers []string
	filename := "openrung_telemetry_outbox.jsonl"
	if platform == brokerapi.PlatformIOS {
		filename = "outbox.json"
	}
	outbox, err := clienttelemetry.NewOutbox(cfg.Directory, filename, func(ctx context.Context, url string, events []clienttelemetry.Event) error {
		dnsMu.RLock()
		dns := append([]string(nil), dnsServers...)
		dnsMu.RUnlock()
		httpClient := brokerapi.NewHTTPClientWithDialControl(0, nil, nil)
		if protector != nil {
			httpClient = brokerapi.NewHTTPClientWithDialControl(0, wsscore.SocketControl(protected), wsscore.ProtectedResolver(protected, dns))
		}
		defer httpClient.CloseIdleConnections()
		err := (clienttelemetry.HTTPClient{BaseURL: url, HTTP: httpClient, AppVersion: cfg.AppVersion, Platform: platform, PlatformVersion: cfg.PlatformVersion}).Send(ctx, events)
		var status *brokerapi.BrokerStatusError
		if errors.As(err, &status) && status.StatusCode >= 400 && status.StatusCode < 500 && status.StatusCode != 408 && status.StatusCode != 429 {
			return fmt.Errorf("%w: %w", clienttelemetry.ErrBatchRejected, err)
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	if len(legacy) > 0 && outbox.EnqueueBatch(legacy) < 0 {
		outbox.Close()
		return nil, errors.New("legacy telemetry import incomplete; retain source")
	}
	runtime := &openRungMobileRuntime{host: host, base: &openRungEngineRuntime{}, statsInterval: time.Second}
	if platform == brokerapi.PlatformIOS {
		runtime.statsInterval = time.Minute
	}
	engine := connectcore.New()
	engine.Platform = platform
	if protector != nil {
		engine.SocketProtector = protected
	}
	engine.Sink = &openRungEngineSink{listener: listener}
	engine.Elevation = openRungMobileElevation{}
	engine.PunchEstablisher = openRungMobilePunchEstablisher(cfg.CoordinatorPins, openRungEnginePunchEstablisher(protector, platform == brokerapi.PlatformIOS, dialOpenRungPunch))
	engine.Mobile = &connectcore.MobileHost{InstallID: cfg.InstallID, AppVersion: cfg.AppVersion, PlatformVersion: cfg.PlatformVersion, Runtime: runtime, Outbox: outbox,
		Settings: func(ctx context.Context) (connectcore.MobileTunnelSettings, error) {
			if err := ctx.Err(); err != nil {
				return connectcore.MobileTunnelSettings{}, err
			}
			raw, err := host.SettingsJSON()
			if err != nil {
				return connectcore.MobileTunnelSettings{}, err
			}
			var input openRungSingBoxInput
			if err := decodeOpenRungObject(raw, &input); err != nil {
				return connectcore.MobileTunnelSettings{}, err
			}
			settings := connectcore.MobileTunnelSettings{TunnelIPv4Address: input.TunnelIPv4Address, TunnelIPv6Address: input.TunnelIPv6Address, MTU: input.MTU, LogLevel: input.LogLevel, ProbeDomainSuffixes: input.ProbeDomainSuffixes, RouteFindProcess: input.RouteFindProcess, ClashAPI: true}
			settings.SplitTunnel = input.SplitTunnel.rules()
			return settings, ctx.Err()
		}, Attributes: func() map[string]string {
			attrs := map[string]string{}
			_ = json.Unmarshal([]byte(host.AttributesJSON()), &attrs)
			return attrs
		},
	}
	if err := engine.SetMode(connectcore.ModeTUN); err != nil {
		outbox.Close()
		return nil, err
	}
	engine.Start()
	var pauseDataPlane func(bool)
	if platform == brokerapi.PlatformIOS {
		pauseDataPlane = runtime.base.setPaused
	}
	return &openRungEngine{engine: engine, runtime: runtime.base, pauseDataPlane: pauseDataPlane, networkDNS: func(servers []string) { dnsMu.Lock(); dnsServers = append([]string(nil), servers...); dnsMu.Unlock() }}, nil
}

type openRungMobileRuntime struct {
	host          OpenRungMobileHost
	base          *openRungEngineRuntime
	statsInterval time.Duration
}

func (r *openRungMobileRuntime) Preflight(ctx context.Context, config []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return CheckConfig(string(config))
}
func (r *openRungMobileRuntime) Run(ctx context.Context, config []byte, telemetry *connectcore.RunTelemetry) (connectcore.MobileTunnelRun, error) {
	var service *openRungMobileService
	run, err := r.base.runWithService(ctx, config, func() (openRungEngineService, error) {
		native, err := r.host.NewRun(&OpenRungRunTelemetry{telemetry})
		if err != nil {
			return nil, err
		}
		if native == nil {
			return nil, errors.New("mobile host returned no run")
		}
		platform := native.Platform()
		if platform == nil {
			_ = native.Close()
			return nil, errors.New("mobile run has no platform")
		}
		core, err := newOpenRungLibboxRuntime(platform).newService()
		if err != nil {
			return nil, errors.Join(err, native.Close())
		}
		ownCtx, cancel := context.WithCancel(ctx)
		service = &openRungMobileService{openRungEngineService: core, server: core.(*openRungLibboxService).server, native: native, ctx: ownCtx, cancel: cancel, telemetry: telemetry, statsInterval: r.statsInterval}
		return service, nil
	})
	if err != nil {
		return nil, err
	}
	return &openRungMobileTunnel{TunnelRun: run, service: service}, nil
}

type openRungMobileService struct {
	openRungEngineService
	server        *CommandServer
	native        OpenRungMobileRun
	ctx           context.Context
	cancel        context.CancelFunc
	telemetry     *connectcore.RunTelemetry
	lifecycleMu   sync.Mutex
	paused        bool
	retired       bool
	opsMu         sync.Mutex
	closed        bool
	ops           sync.WaitGroup
	statsDone     chan struct{}
	statsInterval time.Duration
}

func (s *openRungMobileService) start(config string) error {
	// The run worker calls start then close sequentially. Do not hold the
	// lifecycle lock across native TUN setup: sleep must be able to record its
	// state promptly so the host queue can still deliver a following Stop.
	if err := s.openRungEngineService.start(config); err != nil {
		return err
	}
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	if s.server == nil {
		return nil
	}
	if s.paused {
		s.server.Pause()
	}
	s.statsDone = make(chan struct{})
	go func() {
		defer close(s.statsDone)
		_ = s.server.SubscribeStatus(&daemon.SubscribeStatusRequest{Interval: int64(s.statsInterval)}, &openRungMobileStats{service: s})
	}()
	return nil
}
func (s *openRungMobileService) close() error {
	s.opsMu.Lock()
	s.closed = true
	s.cancel()
	s.opsMu.Unlock()
	s.ops.Wait()
	if s.statsDone != nil {
		<-s.statsDone
	}
	s.lifecycleMu.Lock()
	s.retired = true
	if s.server != nil && s.server.endPauseTimer != nil {
		s.server.endPauseTimer.Stop()
	}
	err := s.openRungEngineService.close()
	s.lifecycleMu.Unlock()
	// Never release the native TUN owner if Go teardown did not finish.
	if err != nil {
		return err
	}
	// The daemon retains the closed instance's traffic manager. Read its final
	// totals after flows stop and before connectcore retires the run's reporter.
	if s.server != nil {
		_ = s.server.SubscribeStatus(&daemon.SubscribeStatusRequest{}, &openRungMobileStats{service: s, once: true})
	}
	return s.native.Close()
}

// Pause and close never race the libbox service; a pause during launch is
// applied once startup completes, and a retired service cannot be woken.
func (s *openRungMobileService) setPaused(paused bool) {
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	s.paused = paused
	if s.retired || s.server == nil || s.statsDone == nil {
		return
	}
	if paused {
		s.server.Pause()
	} else {
		// Pinned libbox's Wake deliberately does nothing on iOS. Resume the
		// device explicitly before connectcore restarts health/recovery work.
		if s.server.endPauseTimer != nil {
			s.server.endPauseTimer.Stop()
		}
		if instance := s.server.Instance(); instance != nil && instance.PauseManager() != nil {
			instance.PauseManager().DeviceWake()
		}
	}
}

func (s *openRungMobileService) operation(ctx context.Context, call func(*OpenRungEngineOperation) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.opsMu.Lock()
	if s.closed {
		s.opsMu.Unlock()
		return context.Canceled
	}
	s.ops.Add(1)
	s.opsMu.Unlock()
	defer s.ops.Done()
	operationCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(s.ctx, cancel)
	defer stop()
	err := call(&OpenRungEngineOperation{operationCtx})
	if operationCtx.Err() != nil {
		return operationCtx.Err()
	}
	return err
}

type openRungMobileTunnel struct {
	connectcore.TunnelRun
	service *openRungMobileService
}

func (r *openRungMobileTunnel) WaitReady(ctx context.Context) error {
	return r.service.operation(ctx, r.service.native.WaitReady)
}
func (r *openRungMobileTunnel) VerifyPath(ctx context.Context, phase connectcore.VerificationPhase) (connectcore.TunnelPathEvidence, error) {
	var evidence connectcore.TunnelPathEvidence
	err := r.service.operation(ctx, func(op *OpenRungEngineOperation) error {
		var result struct {
			Path     string                `json:"path"`
			FreshDNS bool                  `json:"fresh_dns"`
			HTTPS    bool                  `json:"pinned_https"`
			Stage    string                `json:"remote_stage"`
			Error    string                `json:"error"`
			Facts    *openRungFailureInput `json:"failure_facts"`
		}
		if err := json.Unmarshal([]byte(r.service.native.VerifyPath(op, string(phase))), &result); err != nil {
			return err
		}
		if result.Error != "" {
			var err error = errors.New(result.Error)
			if result.Facts != nil {
				err = fmt.Errorf("%s: %w", result.Error, openRungFailureError(*result.Facts))
			}
			if result.Stage != "" {
				return &connectcore.RemotePathError{Stage: result.Stage, Err: err}
			}
			return err
		}
		evidence = connectcore.TunnelPathEvidence{Path: connectcore.TunnelPath(result.Path), FreshDNS: result.FreshDNS, PinnedHTTPS: result.HTTPS}
		return nil
	})
	return evidence, err
}

type openRungMobileStats struct {
	service *openRungMobileService
	once    bool
}

func (s *openRungMobileStats) Send(status *daemon.Status) error {
	if status.TrafficAvailable && s.service.telemetry != nil {
		s.service.telemetry.UpdateTraffic(status.UplinkTotal, status.DownlinkTotal)
	}
	if s.once {
		return io.EOF
	}
	return nil
}
func (s *openRungMobileStats) Context() context.Context   { return s.service.ctx }
func (*openRungMobileStats) SetHeader(metadata.MD) error  { return nil }
func (*openRungMobileStats) SendHeader(metadata.MD) error { return nil }
func (*openRungMobileStats) SetTrailer(metadata.MD)       {}
func (*openRungMobileStats) SendMsg(any) error            { return errors.New("unexpected status send") }
func (*openRungMobileStats) RecvMsg(any) error            { return errors.New("status is send-only") }

// OpenRungTunName resolves the exact descriptor opened by Android's VpnService.
func OpenRungTunName(fd int32) (string, error) { return getTunnelName(fd) }
