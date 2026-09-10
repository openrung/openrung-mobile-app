package libbox

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openrung/openrung/punchcore"
)

// Independent expectations from shipping NatPunchClient at mobile main 53e03d9.
func TestMobilePunchRetainsCoordinatorPinProtectedDialAndNoRedirects(t *testing.T) {
	var redirected atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirected" {
			redirected.Add(1)
		}
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/redirected", http.StatusFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	var dials atomic.Int32
	transport := &http.Transport{DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		dials.Add(1)
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}}
	digest := sha256.Sum256(server.Certificate().Raw)
	endpoint, _ := url.Parse(server.URL)
	hub := punchcore.HubClient{BaseURL: server.URL, HTTPClient: &http.Client{Transport: transport}}
	for _, good := range []bool{true, false} {
		pin := hex.EncodeToString(digest[:])
		if !good {
			pin = hex.EncodeToString(make([]byte, 32))
		}
		client, err := openRungMobilePunchClient(hub, map[string]string{endpoint.Hostname(): pin})
		if err != nil {
			t.Fatal(err)
		}
		defer client.CloseIdleConnections()
		response, err := client.Get(server.URL + "/redirect")
		if !good {
			if err == nil {
				response.Body.Close()
				t.Fatal("wrong pin accepted")
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusFound || redirected.Load() != 0 {
			t.Fatal("coordinator redirect followed")
		}
		if client.Timeout != 10*time.Second {
			t.Fatal("coordinator timeout changed")
		}
	}
	if dials.Load() != 2 || transport.TLSClientConfig != nil {
		t.Fatal("protected dial hook lost or engine transport mutated")
	}
}

func TestMobilePunchRejectsLegacyHTTPAndUnpinnedIPBeforeDial(t *testing.T) {
	client := &http.Client{Transport: &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
		t.Fatal("invalid coordinator dialed")
		return nil, nil
	}}}
	for _, endpoint := range []string{"http://127.0.0.1:9444", "https://127.0.0.1:9444", "https://user@example.org", "https://example.org?q=x", "https://example.org/#x", "https://example.org:70000"} {
		if _, err := openRungMobilePunchClient(punchcore.HubClient{BaseURL: endpoint, HTTPClient: client}, nil); err == nil {
			t.Fatalf("accepted %s", endpoint)
		}
	}
	allowed, err := openRungMobilePunchClient(punchcore.HubClient{BaseURL: "https://coordinator.example", HTTPClient: client}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg := allowed.Transport.(*http.Transport).TLSClientConfig; cfg != nil && cfg.InsecureSkipVerify {
		t.Fatal("public CA verification disabled")
	}
}
