// Package libbox exposes the OpenRung NAT-punch client through the same
// gomobile package as sing-box. Keeping both APIs in one generated AAR is
// important: two gomobile AARs would each ship go.Seq and a separate Go
// runtime, which Android cannot safely link into one application.
package libbox

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/openrung/openrung/punchcore"
	"github.com/sagernet/sing-box/experimental/libbox/internal/openrungpunch"
)

// OpenRungPunchProtector is implemented by Android's VpnService. Protect is
// called with the long-lived UDP socket before the result is returned to the
// app and before libbox installs the VPN. Returning false makes punching fail
// closed and lets Kotlin fall back to the ordinary relay-hub path.
type OpenRungPunchProtector interface {
	Protect(fd int64) bool
}

// OpenRungPunchListener reports loss of an already-established direct path.
// Android handles the callback asynchronously and switches the same relay
// to its RelayHub endpoint; it must not call Close re-entrantly from here.
type OpenRungPunchListener interface {
	Closed(reason string)
}

// OpenRungPunchResult is a gomobile-safe snapshot of one establishment attempt.
// A successful result means the client owns a live QUIC path and loopback TCP
// bridge until Close is called. Failed results own no network resources.
type OpenRungPunchResult struct {
	succeeded  bool
	reason     string
	errorText  string
	bridgeHost string
	bridgePort int32
	peerIP     string
	sessionID  string
	natClass   string
	rttMillis  int64
}

func (r *OpenRungPunchResult) Succeeded() bool { return r != nil && r.succeeded }
func (r *OpenRungPunchResult) Reason() string {
	if r == nil {
		return ""
	}
	return r.reason
}
func (r *OpenRungPunchResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.errorText
}
func (r *OpenRungPunchResult) BridgeHost() string {
	if r == nil {
		return ""
	}
	return r.bridgeHost
}
func (r *OpenRungPunchResult) BridgePort() int32 {
	if r == nil {
		return 0
	}
	return r.bridgePort
}
func (r *OpenRungPunchResult) PeerIP() string {
	if r == nil {
		return ""
	}
	return r.peerIP
}
func (r *OpenRungPunchResult) SessionID() string {
	if r == nil {
		return ""
	}
	return r.sessionID
}
func (r *OpenRungPunchResult) NATClass() string {
	if r == nil {
		return ""
	}
	return r.natClass
}
func (r *OpenRungPunchResult) RTTMillis() int64 {
	if r == nil {
		return 0
	}
	return r.rttMillis
}

// OpenRungPunchClient owns both an in-flight establishment and, on success,
// the live bridge/QUIC/UDP resources. Close is safe during Establish and is the
// cancellation path used by Android disconnect and relay failover.
type OpenRungPunchClient struct {
	mu          sync.Mutex
	ctx         context.Context
	cancel      context.CancelFunc
	baseURL     string
	relayID     string
	insecureTLS bool
	certSHA256  string
	protector   OpenRungPunchProtector
	listener    OpenRungPunchListener
	est         *openrungpunch.Establishment
	closed      bool
	attempted   bool
}

// NewOpenRungPunchClient prepares a cancelable client. Establish performs the
// blocking network work and should be called from a Kotlin IO dispatcher.
func NewOpenRungPunchClient(
	baseURL string,
	relayID string,
	insecureTLS bool,
	certSHA256 string,
	protector OpenRungPunchProtector,
	listener OpenRungPunchListener,
) *OpenRungPunchClient {
	ctx, cancel := context.WithCancel(context.Background())
	return &OpenRungPunchClient{
		ctx:         ctx,
		cancel:      cancel,
		baseURL:     baseURL,
		relayID:     relayID,
		insecureTLS: insecureTLS,
		certSHA256:  certSHA256,
		protector:   protector,
		listener:    listener,
	}
}

// Establish tries the shared punchcore reflector -> rendezvous -> UDP punch
// -> QUIC -> loopback bridge flow. Every failure is returned as data so Android
// can record the precise reason and continue through the existing hub endpoint.
func (c *OpenRungPunchClient) Establish() *OpenRungPunchResult {
	if c == nil {
		return failedPunchResult("client", errors.New("nil punch client"), "")
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return failedPunchResult("cancelled", context.Canceled, "")
	}
	if c.attempted {
		c.mu.Unlock()
		return failedPunchResult("client", errors.New("punch client Establish called more than once"), "")
	}
	c.attempted = true
	ctx := c.ctx
	baseURL := c.baseURL
	relayID := c.relayID
	insecureTLS := c.insecureTLS
	certSHA256 := c.certSHA256
	protector := c.protector
	c.mu.Unlock()

	httpClient, err := openRungPunchHTTPClient(insecureTLS, certSHA256)
	if err != nil {
		return failedPunchResult("config", err, "")
	}

	dialer := &openrungpunch.Dialer{
		Hub: punchcore.HubClient{
			BaseURL:    baseURL,
			HTTPClient: httpClient,
		},
		RelayID: relayID,
		ProtectSocket: func(fd int64) bool {
			return protector != nil && protector.Protect(fd)
		},
	}
	est, attempt, err := dialer.Establish(ctx)
	if err != nil {
		return failedPunchResult(attempt.Reason, err, attempt.NATClass)
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		_ = est.Close()
		return failedPunchResult("cancelled", context.Canceled, attempt.NATClass)
	}
	c.est = est
	c.mu.Unlock()

	go c.serveBridge(ctx, est)

	return &OpenRungPunchResult{
		succeeded:  true,
		bridgeHost: est.BridgeHost,
		bridgePort: int32(est.BridgePort),
		peerIP:     est.PeerIP,
		sessionID:  est.SessionID,
		natClass:   attempt.NATClass,
		rttMillis:  attempt.RTTMillis,
	}
}

func (c *OpenRungPunchClient) serveBridge(ctx context.Context, est *openrungpunch.Establishment) {
	err := est.Bridge.Serve(ctx)
	if ctx.Err() != nil {
		return
	}
	c.mu.Lock()
	listener := c.listener
	shouldNotify := !c.closed && c.est == est && listener != nil
	c.mu.Unlock()
	if !shouldNotify {
		return
	}
	reason := "direct QUIC path closed"
	if err != nil {
		reason = err.Error()
	}
	listener.Closed(reason)
}

func failedPunchResult(reason string, err error, natClass string) *OpenRungPunchResult {
	if reason == "" {
		reason = "unknown"
	}
	message := ""
	if err != nil {
		message = err.Error()
	}
	return &OpenRungPunchResult{reason: reason, errorText: message, natClass: natClass}
}

// Close cancels any blocked HTTP/UDP/QUIC work and then closes a live bridge.
// It is idempotent and may be called concurrently with Establish.
func (c *OpenRungPunchClient) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.cancel()
	est := c.est
	c.est = nil
	c.protector = nil
	c.listener = nil
	c.mu.Unlock()
	if est != nil {
		_ = est.Close()
	}
}

func openRungPunchHTTPClient(insecure bool, fingerprint string) (*http.Client, error) {
	pin, err := decodeCertFingerprint(fingerprint)
	if err != nil {
		return nil, err
	}
	if insecure && len(pin) == 0 {
		return nil, errors.New("self-signed punch coordinator requires a SHA-256 certificate pin")
	}
	if !insecure && len(pin) == 0 {
		// Preserves the historical hardened default for public-CA coordinators:
		// 10s timeout, redirects refused, keep-alives disabled.
		return punchcore.HardenedHTTPClient(), nil
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if len(pin) != 0 {
		// Exact leaf pinning replaces public-CA verification for the deployed self-signed
		// bare-IP coordinator. The callback also enforces the certificate validity window.
		tlsConfig.InsecureSkipVerify = true //nolint:gosec // authenticated below by exact SHA-256 pin
		tlsConfig.VerifyPeerCertificate = func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("punch coordinator presented no certificate")
			}
			actual := sha256.Sum256(rawCerts[0])
			if subtle.ConstantTimeCompare(actual[:], pin) != 1 {
				return errors.New("punch coordinator certificate pin mismatch")
			}
			certificate, err := x509.ParseCertificate(rawCerts[0])
			if err != nil {
				return fmt.Errorf("parse punch coordinator certificate: %w", err)
			}
			now := time.Now()
			if now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) {
				return errors.New("punch coordinator certificate is outside its validity window")
			}
			return nil
		}
	}
	return &http.Client{
		Timeout:       10 * time.Second,
		CheckRedirect: rejectPunchRedirect,
		Transport: &http.Transport{
			DisableKeepAlives: true,
			TLSClientConfig:   tlsConfig,
		},
	}, nil
}

func decodeCertFingerprint(value string) ([]byte, error) {
	normalized := strings.NewReplacer(":", "", " ", "").Replace(strings.TrimSpace(value))
	if normalized == "" {
		return nil, nil
	}
	decoded, err := hex.DecodeString(normalized)
	if err != nil || len(decoded) != sha256.Size {
		return nil, errors.New("invalid punch coordinator SHA-256 certificate pin")
	}
	return decoded, nil
}

func rejectPunchRedirect(_ *http.Request, _ []*http.Request) error {
	// Never let an unauthenticated/self-signed coordinator redirect the client
	// to a different scheme or host. The signed relay directory is the only
	// source allowed to select the punch endpoint.
	return http.ErrUseLastResponse
}
