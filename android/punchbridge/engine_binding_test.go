package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openrung/openrung/brokerapi"
	"github.com/openrung/openrung/connectcore"
	"github.com/openrung/openrung/punchcore"
	"github.com/sagernet/sing-box/experimental/libbox/internal/openrungpunch"
)

type engineListenerFunc func(string)

func (f engineListenerFunc) OnEvent(value string) { f(value) }

type engineProtectorFunc func(int32) bool

func (f engineProtectorFunc) Protect(fd int32) bool { return f(fd) }

type engineTestService struct {
	startFn func(string) error
	closeFn func() error
	exit    chan error
	closed  atomic.Int32
}

func (s *engineTestService) start(cfg string) error {
	if s.startFn != nil {
		return s.startFn(cfg)
	}
	return nil
}
func (s *engineTestService) close() error {
	s.closed.Add(1)
	if s.closeFn != nil {
		return s.closeFn()
	}
	return nil
}
func (s *engineTestService) done() <-chan error { return s.exit }
func engineTestRuntime(s *engineTestService) *openRungEngineRuntime {
	return &openRungEngineRuntime{newService: func() (openRungEngineService, error) { return s, nil }}
}

func TestOpenRungEngineRuntimeLifecycle(t *testing.T) {
	s := &engineTestService{exit: make(chan error, 1)}
	rt := engineTestRuntime(s)
	run, err := rt.Run(context.Background(), []byte(`{"test":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rt.Run(context.Background(), nil); err == nil {
		t.Fatal("overlapping run accepted")
	}
	crash := errors.New("libbox: simulated crash")
	s.exit <- crash
	if err := <-run.Done(); !errors.Is(err, crash) {
		t.Fatalf("lost crash: %v", err)
	}
	if _, ok := <-run.Done(); ok {
		t.Fatal("exit channel not closed")
	}
	if err := run.Stop(time.Second); err != nil {
		t.Fatal(err)
	}
	if s.closed.Load() != 1 {
		t.Fatal("service not closed exactly once")
	}
	run, err = rt.Run(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := run.Stop(time.Second); err != nil {
		t.Fatal(err)
	}
	if err := <-run.Done(); err != nil {
		t.Fatalf("requested stop reported crash: %v", err)
	}
}

func TestOpenRungEngineRuntimeStopDuringStart(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	s := &engineTestService{startFn: func(string) error { close(entered); <-release; return nil }}
	rt := engineTestRuntime(s)
	run, err := rt.Run(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	<-entered
	if err := run.Stop(time.Millisecond); err == nil {
		t.Fatal("hung startup must report stop deadline")
	}
	if _, err := rt.Run(context.Background(), nil); err == nil {
		t.Fatal("overlapped a blocked launch")
	}
	engine, err := newOpenRungEngine(`{}`, brokerapi.PlatformIOS, nil, engineListenerFunc(func(string) {}), rt, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := engine.Stop(1); err == nil {
		t.Fatal("binding hid incomplete native teardown")
	}
	close(release)
	if err := run.Stop(time.Second); err != nil {
		t.Fatal(err)
	}
	if err := <-run.Done(); err != nil || s.closed.Load() != 1 {
		t.Fatalf("late launch not cleaned: %v", err)
	}
	if err := engine.Stop(1); err != nil {
		t.Fatalf("completed cleanup still reported failure: %v", err)
	}
}

func TestOpenRungEngineRuntimeLaunchFailureAndPoisonedClose(t *testing.T) {
	for _, closeFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "launch", true: "close"}[closeFails], func(t *testing.T) {
			launchErr := errors.New("libbox config rejected")
			closeErr := errors.New("TUN close failed")
			s := &engineTestService{startFn: func(string) error { return launchErr }}
			if closeFails {
				s.closeFn = func() error { return closeErr }
			}
			rt := engineTestRuntime(s)
			run, err := rt.Run(context.Background(), nil)
			if err != nil {
				t.Fatal(err)
			}
			if err := <-run.Done(); err == nil {
				t.Fatal("lost startup/close error")
			}
			if err := run.Stop(time.Second); (err != nil) != closeFails {
				t.Fatalf("close outcome %v", err)
			}
			if closeFails {
				if !errors.Is(rt.shutdownError(), closeErr) {
					t.Fatal("shutdown hid the native teardown cause")
				}
				if _, err := rt.Run(context.Background(), nil); err == nil {
					t.Fatal("poisoned runtime restarted")
				}
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	rt := engineTestRuntime(nil)
	if _, err := rt.Run(ctx, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled launch: %v", err)
	}
}

func TestOpenRungEngineConfigurationAndNetworkCallbacks(t *testing.T) {
	listener := engineListenerFunc(func(string) {})
	rt := engineTestRuntime(&engineTestService{})
	if _, err := newOpenRungEngine(`{}`, brokerapi.PlatformAndroid, nil, listener, rt, false); err == nil {
		t.Fatal("missing protector accepted")
	}
	for _, cfg := range []string{`null`, `{"unknown":1}`, `{} {}`, `{"mode":"bad"}`, `{"mtu":-1}`} {
		_, err := newOpenRungEngine(cfg, brokerapi.PlatformIOS, nil, listener, rt, true)
		if err == nil {
			t.Fatalf("accepted config %s", cfg)
		}
	}
	e, err := newOpenRungEngine(`{"mode":"proxy","punch_enabled":false}`, brokerapi.PlatformIOS, nil, listener, rt, true)
	if err != nil {
		t.Fatal(err)
	}
	if e.engine.PunchEstablisher == nil {
		t.Fatal("ADR-001 punch establisher invariant violated")
	}
	if err := e.NetworkChanged(true, "wifi", `["192.0.2.53"]`); err != nil {
		t.Fatal(err)
	}
	if err := e.NetworkChanged(true, "cellular", `["dns.example"]`); err == nil {
		t.Fatal("DNS hostname accepted")
	}
	e.Pause()
	e.Resume()
	if err := e.Stop(1); err != nil {
		t.Fatal(err)
	}
	if err := e.Stop(-1); err == nil {
		t.Fatal("negative budget accepted")
	}
	var state connectcore.State
	if json.Unmarshal([]byte(e.StateJSON()), &state) != nil || state.Status != connectcore.StatusDisconnected {
		t.Fatal("invalid state snapshot")
	}
}

func TestOpenRungEngineCallbackSequence(t *testing.T) {
	var sequences []uint64
	s := &openRungEngineSink{listener: engineListenerFunc(func(raw string) {
		var event struct {
			Version  int
			Sequence uint64
			Kind     string
		}
		if err := json.Unmarshal([]byte(raw), &event); err != nil {
			t.Error(err)
		}
		if event.Version != 1 || event.Kind != "state" {
			t.Error("invalid event envelope")
		}
		sequences = append(sequences, event.Sequence)
	})}
	var wg sync.WaitGroup
	for range 50 {
		wg.Go(func() { s.StateChanged(connectcore.State{Status: connectcore.StatusConnecting}) })
	}
	wg.Wait()
	for i, seq := range sequences {
		if seq != uint64(i+1) {
			t.Fatal("out of order callback")
		}
	}
}

func TestOpenRungEnginePunchUsesProtectedHubAndClosesInvalidPath(t *testing.T) {
	called := false
	protect := engineProtectorFunc(func(int32) bool { called = true; return true })
	establish := openRungEnginePunchEstablisher(protect, false, func(_ context.Context, d *openrungpunch.Dialer) (*openrungpunch.Establishment, punchcore.PunchResult, error) {
		if d.Hub.BaseURL != "https://hub.example" || d.RelayID != "relay" || d.AllowUnprotectedSocket {
			t.Error("lost punch inputs")
		}
		if !d.ProtectSocket(12) {
			t.Error("lost protector")
		}
		return &openrungpunch.Establishment{}, punchcore.PunchResult{}, nil
	})
	path, result, err := establish(context.Background(), punchcore.HubClient{BaseURL: "https://hub.example"}, "relay")
	if path != nil || err == nil || result.Reason != "bridge" || !called {
		t.Fatal("invalid punch path accepted")
	}
}

// Run separately, without -race, for reproducible retained-heap evidence. This
// measures loaded idle Go engines, not libbox, device RSS, or the iOS ceiling.
func TestOpenRungEngineLoadedMemory(t *testing.T) {
	if testing.Short() {
		t.Skip("memory measurement")
	}
	const count = 1000
	engines := make([]*openRungEngine, count)
	listener := engineListenerFunc(func(string) {})
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	goroutines := runtime.NumGoroutine()
	for i := range engines {
		e, err := newOpenRungEngine(`{"mode":"proxy"}`, brokerapi.PlatformIOS, nil, listener, engineTestRuntime(&engineTestService{}), true)
		if err != nil {
			t.Fatal(err)
		}
		engines[i] = e
	}
	runtime.GC()
	runtime.ReadMemStats(&after)
	t.Logf("%d idle engines: retained heap delta=%d bytes; bytes/engine=%d; goroutine delta=%d; Go=%s %s/%s", count, int64(after.HeapAlloc)-int64(before.HeapAlloc), (int64(after.HeapAlloc)-int64(before.HeapAlloc))/count, runtime.NumGoroutine()-goroutines, runtime.Version(), runtime.GOOS, runtime.GOARCH)
	runtime.KeepAlive(engines)
}
