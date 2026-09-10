//go:build openrung_libbox

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openrung/openrung/connectcore"
)

type mobileTestNative struct {
	OpenRungMobileRun
	ready    func(*OpenRungEngineOperation) error
	evidence string
	closeFn  func() error
}

func (n *mobileTestNative) WaitReady(op *OpenRungEngineOperation) error        { return n.ready(op) }
func (n *mobileTestNative) VerifyPath(*OpenRungEngineOperation, string) string { return n.evidence }
func (n *mobileTestNative) Close() error {
	if n.closeFn != nil {
		return n.closeFn()
	}
	return nil
}

type mobileTestCore struct{ closeFn func() error }

func (*mobileTestCore) start(string) error { return nil }
func (*mobileTestCore) done() <-chan error { return nil }
func (c *mobileTestCore) close() error {
	if c.closeFn != nil {
		return c.closeFn()
	}
	return nil
}

func mobileTestService(n *mobileTestNative) *openRungMobileService {
	ctx, cancel := context.WithCancel(context.Background())
	return &openRungMobileService{openRungEngineService: &mobileTestCore{}, native: n, ctx: ctx, cancel: cancel}
}

func TestOpenRungLibboxMobileCloseCancelsAndJoinsNativeOperations(t *testing.T) {
	entered, exited := make(chan struct{}), make(chan struct{})
	var coreClosed, nativeClosed atomic.Bool
	n := &mobileTestNative{ready: func(op *OpenRungEngineOperation) error {
		close(entered)
		for !op.IsCancelled() {
			time.Sleep(time.Millisecond)
		}
		close(exited)
		return errors.New("native cancelled")
	}, closeFn: func() error {
		if !coreClosed.Load() {
			t.Error("native fd released before core close")
		}
		nativeClosed.Store(true)
		return nil
	}}
	s := mobileTestService(n)
	s.openRungEngineService = &mobileTestCore{closeFn: func() error {
		select {
		case <-exited:
		default:
			t.Error("core closed before native probe exited")
		}
		coreClosed.Store(true)
		return nil
	}}
	tunnel := &openRungMobileTunnel{service: s}
	result := make(chan error, 1)
	go func() { result <- tunnel.WaitReady(context.Background()) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("readiness did not start")
	}
	if err := s.close(); err != nil {
		t.Fatal(err)
	}
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation lost: %v", err)
	}
	if !nativeClosed.Load() {
		t.Fatal("native owner leaked")
	}
	if err := tunnel.WaitReady(context.Background()); !errors.Is(err, context.Canceled) {
		t.Fatal("retired run accepted operation")
	}
}

func TestOpenRungLibboxMobileFailedCoreCloseRetainsNativeOwner(t *testing.T) {
	n := &mobileTestNative{closeFn: func() error { t.Fatal("released a live core's TUN"); return nil }}
	s := mobileTestService(n)
	s.openRungEngineService = &mobileTestCore{closeFn: func() error { return errors.New("core close failed") }}
	if err := s.close(); err == nil {
		t.Fatal("teardown failure hidden")
	}
}

func TestOpenRungLibboxMobileEvidenceAndErrorClassification(t *testing.T) {
	for _, tc := range []struct {
		raw    string
		remote bool
		failed bool
	}{
		{`{"path":"android_vpn_network","fresh_dns":true,"pinned_https":true}`, false, false},
		{`{"error":"probe timeout","remote_stage":"dns_probe"}`, true, true},
		{`{"error":"HTTP 503","remote_stage":"internet_probe"}`, true, true},
		{`{"error":"VPN Network unavailable"}`, false, true},
		{`invalid`, false, true},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			s := mobileTestService(&mobileTestNative{evidence: tc.raw})
			defer s.cancel()
			tunnel := &openRungMobileTunnel{service: s}
			proof, err := tunnel.VerifyPath(context.Background(), connectcore.VerificationStartup)
			var remote *connectcore.RemotePathError
			if (err != nil) != tc.failed || errors.As(err, &remote) != tc.remote {
				t.Fatalf("classification changed: %v", err)
			}
			if !tc.failed && (proof.Path != connectcore.PathAndroidVPN || !proof.FreshDNS || !proof.PinnedHTTPS) {
				t.Fatalf("lost proof: %+v", proof)
			}
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			if _, err := tunnel.VerifyPath(ctx, connectcore.VerificationHealth); !errors.Is(err, context.Canceled) {
				t.Fatalf("parent cancellation became remote: %v", err)
			}
		})
	}
}

func TestOpenRungLibboxMobileJSONRejectsInvalidEnvelopes(t *testing.T) {
	for _, raw := range []string{"null", "[]", "{} {}", "{\"unknown\":1}"} {
		var cfg openRungMobileConfig
		if err := decodeOpenRungMobileJSON(raw, &cfg); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	var cfg openRungMobileConfig
	if err := decodeOpenRungMobileJSON(`{"install_id":"abc"}`, &cfg); err != nil || cfg.InstallID != "abc" {
		t.Fatal(err)
	}
}

type mobileTestHost struct{ OpenRungMobileHost }
type mobileTestProtector struct{}

func (mobileTestProtector) Protect(int32) bool { return false }

type mobileTestListener struct{}

func (mobileTestListener) OnEvent(string) {}

func TestOpenRungLibboxMobileBorrowsExistingIdentityAndDurableOutbox(t *testing.T) {
	cfg := openRungMobileConfig{InstallID: "E6B1A1DE-9F0F-4C1A-8BB1-1F2B3C4D5E6F", AppVersion: "0.3.8", PlatformVersion: "37", Directory: t.TempDir(),
		LegacyBatch: `[{"event_id":"legacy-1","event":"connection_ended","client_id":"old-client","session_id":"old-session","timestamp":"2026-09-01T00:00:00Z"}]`}
	raw, _ := json.Marshal(cfg)
	e, err := NewOpenRungMobileEngineForAndroid(string(raw), mobileTestProtector{}, mobileTestHost{}, mobileTestListener{})
	if err != nil {
		t.Fatal(err)
	}
	h := e.(*openRungEngine).engine.Mobile
	defer h.Outbox.Close()
	defer e.Stop(1)
	if h.InstallID != cfg.InstallID || h.AppVersion != cfg.AppVersion || h.PlatformVersion != cfg.PlatformVersion {
		t.Fatal("native identity changed")
	}
	if h.Outbox.PendingCount() != 1 {
		t.Fatal("legacy event was not imported")
	}
	if _, err := NewOpenRungMobileEngineForAndroid(string(raw), mobileTestProtector{}, mobileTestHost{}, mobileTestListener{}); err == nil {
		t.Fatal("second owner acquired the same outbox")
	}
}
