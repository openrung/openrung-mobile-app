package libbox

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openrung/openrung/punchcore"
	"github.com/sagernet/sing-box/experimental/libbox/internal/openrungpunch"
)

type testProtector struct {
	allow  bool
	calls  atomic.Int32
	lastFD atomic.Int64
}

func (p *testProtector) Protect(fd int64) bool {
	p.calls.Add(1)
	p.lastFD.Store(fd)
	return p.allow
}

func TestProtectFailureStopsBeforeDiscovery(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/punch/config" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"reflector_addrs":["127.0.0.1:9"],"quic_alpn":"openrung-punch/1","ttl_ms":6000}`)
	}))
	defer server.Close()

	protector := &testProtector{allow: false}
	client := NewOpenRungPunchClient(server.URL, "relay-test", false, "", protector, nil)
	defer client.Close()
	result := client.Establish()
	if result.Succeeded() || result.Reason() != "protect" {
		t.Fatalf("result = success:%v reason:%q error:%q", result.Succeeded(), result.Reason(), result.ErrorText())
	}
	if protector.calls.Load() != 1 || protector.lastFD.Load() < 0 {
		t.Fatalf("protector calls=%d fd=%d", protector.calls.Load(), protector.lastFD.Load())
	}
	if second := client.Establish(); second.Succeeded() || second.Reason() != "client" {
		t.Fatalf("second Establish should be rejected, got success:%v reason:%q", second.Succeeded(), second.Reason())
	}
}

func TestAndroidConstructorRequiresSocketProtector(t *testing.T) {
	client := NewOpenRungPunchClient("https://coordinator.example", "relay-test", false, "", nil, nil)
	var dialed atomic.Bool
	client.dial = func(
		context.Context,
		*openrungpunch.Dialer,
	) (*openrungpunch.Establishment, punchcore.PunchResult, error) {
		dialed.Store(true)
		return nil, punchcore.PunchResult{}, errors.New("must not dial")
	}

	result := client.Establish()
	client.Close()
	if result.Succeeded() || result.Reason() != "protect" || dialed.Load() {
		t.Fatalf(
			"nil Android protector result = success:%v reason:%q dialed:%v",
			result.Succeeded(),
			result.Reason(),
			dialed.Load(),
		)
	}
}

func TestExplicitIOSPathSelectsNilProtector(t *testing.T) {
	const (
		coordinatorURL = "https://coordinator.example"
		relayID        = "relay-ios"
	)
	client := newOpenRungPunchClient(
		coordinatorURL,
		relayID,
		false,
		"",
		nil,
		nil,
		false,
	)
	var dialed atomic.Bool
	client.dial = func(
		_ context.Context,
		dialer *openrungpunch.Dialer,
	) (*openrungpunch.Establishment, punchcore.PunchResult, error) {
		dialed.Store(true)
		if dialer.Hub.BaseURL != coordinatorURL || dialer.RelayID != relayID {
			t.Fatalf("iOS dialer changed coordinator/relay: %+v", dialer)
		}
		if dialer.ProtectSocket != nil {
			t.Fatal("iOS constructor installed an Android socket protector")
		}
		if !dialer.AllowUnprotectedSocket {
			t.Fatal("iOS constructor did not select the explicit nil-protector path")
		}
		return nil, punchcore.PunchResult{Reason: "discovery"}, errors.New("test stop")
	}

	result := client.Establish()
	client.Close()
	if result.Succeeded() || result.Reason() != "discovery" || !dialed.Load() {
		t.Fatalf(
			"iOS result = success:%v reason:%q dialed:%v",
			result.Succeeded(),
			result.Reason(),
			dialed.Load(),
		)
	}
}

func TestIOSNamedConstructorsAllowUnprotectedSocketsOnlyOnIOS(t *testing.T) {
	for _, test := range []struct {
		goos             string
		requireProtector bool
	}{
		{goos: "ios", requireProtector: false},
		{goos: "android", requireProtector: true},
		{goos: "darwin", requireProtector: true},
		{goos: "linux", requireProtector: true},
	} {
		if got := iosConstructorRequiresSocketProtectorForGOOS(test.goos); got != test.requireProtector {
			t.Errorf(
				"GOOS %q requires protector = %v, want %v",
				test.goos,
				got,
				test.requireProtector,
			)
		}
	}

	want := runtime.GOOS != "ios"
	punchClient := NewOpenRungPunchClientForIOS(
		"https://coordinator.example",
		"relay-ios",
		false,
		"",
		nil,
	)
	defer punchClient.Close()
	if punchClient.requireProtector != want {
		t.Fatalf(
			"punch iOS constructor requires protector on %s = %v, want %v",
			runtime.GOOS,
			punchClient.requireProtector,
			want,
		)
	}

	wssClient := NewOpenRungWSSClientForIOS(testWSSFrontURL, testWSSTicket, nil)
	defer wssClient.Close()
	if wssClient.requireProtector != want {
		t.Fatalf(
			"WSS iOS constructor requires protector on %s = %v, want %v",
			runtime.GOOS,
			wssClient.requireProtector,
			want,
		)
	}
}

func TestCloseCancelsBlockedEstablish(t *testing.T) {
	requestStarted := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(requestStarted)
		<-r.Context().Done()
	}))
	defer server.Close()

	client := NewOpenRungPunchClient(server.URL, "relay-test", false, "", &testProtector{allow: true}, nil)
	resultChannel := make(chan *OpenRungPunchResult, 1)
	go func() { resultChannel <- client.Establish() }()
	<-requestStarted
	var closes sync.WaitGroup
	closes.Add(2)
	go func() {
		defer closes.Done()
		client.Close()
	}()
	go func() {
		defer closes.Done()
		client.Close()
	}()
	closes.Wait()

	select {
	case result := <-resultChannel:
		if result.Succeeded() {
			t.Fatal("cancelled Establish unexpectedly succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not cancel the blocked Establish")
	}
}

func TestPinnedPunchHTTPClient(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer server.Close()

	fingerprint := sha256.Sum256(server.Certificate().Raw)
	client, err := openRungPunchHTTPClient(true, hex.EncodeToString(fingerprint[:]))
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatalf("pinned request failed: %v", err)
	}
	_ = response.Body.Close()

	badPin := make([]byte, sha256.Size)
	badClient, err := openRungPunchHTTPClient(true, hex.EncodeToString(badPin))
	if err != nil {
		t.Fatal(err)
	}
	if response, err = badClient.Get(server.URL); err == nil {
		_ = response.Body.Close()
		t.Fatal("request with the wrong coordinator pin unexpectedly succeeded")
	}
}

func TestSelfSignedPunchHTTPClientRequiresPin(t *testing.T) {
	if _, err := openRungPunchHTTPClient(true, ""); err == nil {
		t.Fatal("self-signed transport without a certificate pin unexpectedly succeeded")
	}
}
