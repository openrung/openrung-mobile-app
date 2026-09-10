package libbox

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/openrung/openrung/connectcore"
	"github.com/openrung/openrung/punchcore"
)

// Preserve Android's shipping coordinator trust boundary while connectcore owns
// punch selection. The clone keeps the engine's protected dialer/DNS resolver.
func openRungMobilePunchEstablisher(pins map[string]string, establish connectcore.PunchEstablisher) connectcore.PunchEstablisher {
	return func(ctx context.Context, hub punchcore.HubClient, relayID string) (*connectcore.PunchPath, punchcore.PunchResult, error) {
		client, err := openRungMobilePunchClient(hub, pins)
		if err != nil {
			return nil, punchcore.PunchResult{Reason: "hub"}, err
		}
		defer client.CloseIdleConnections()
		hub.HTTPClient = client
		return establish(ctx, hub, relayID)
	}
}

func openRungMobilePunchClient(hub punchcore.HubClient, pins map[string]string) (*http.Client, error) {
	endpoint, err := url.Parse(hub.BaseURL)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.ForceQuery || endpoint.Fragment != "" {
		return nil, errors.New("mobile punch requires an explicit HTTPS coordinator without user info, query or fragment")
	}
	if p := endpoint.Port(); p != "" {
		port, err := strconv.Atoi(p)
		if err != nil || port < 1 || port > 65535 {
			return nil, errors.New("invalid punch coordinator port")
		}
	}
	pin := pins[strings.ToLower(endpoint.Hostname())]
	if net.ParseIP(endpoint.Hostname()) != nil && pin == "" {
		return nil, errors.New("IP coordinator requires an app certificate pin")
	}
	hardened, err := openRungPunchHTTPClient(false, pin)
	if err != nil {
		return nil, err
	}
	if hub.HTTPClient == nil {
		return nil, errors.New("mobile punch requires the engine's protected HTTP client")
	}
	original, ok := hub.HTTPClient.Transport.(*http.Transport)
	if !ok || original == nil || original.DialContext == nil {
		return nil, errors.New("mobile punch requires the engine's protected HTTP transport")
	}
	transport := original.Clone()
	transport.DisableKeepAlives = true
	transport.TLSClientConfig = hardened.Transport.(*http.Transport).TLSClientConfig
	hardened.Transport = transport
	return hardened, nil
}
