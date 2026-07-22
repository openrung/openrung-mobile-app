package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"slices"
	"strings"
	"sync"

	"github.com/openrung/openrung/wsscore"
)

const unexpectedWSSCloseReason = "WSS session stopped unexpectedly"

// OpenRungWSSProtector is implemented by Android's VpnService. Protect must
// delegate to VpnService.protect(fd). Returning false prevents the outer CDN
// socket from connecting; wsscore never retries without protection.
type OpenRungWSSProtector interface {
	Protect(fd int32) bool
}

// OpenRungWSSListener reports loss of an established WSS transport. The
// callback contains no front URL, ticket, or underlying error text. A caller
// may call Close from the callback; the serving goroutine is already released.
type OpenRungWSSListener interface {
	Closed(reason string)
}

// OpenRungWSSResult is a gomobile-safe snapshot of one WSS dial. A successful
// result owns a live wsscore client and loopback adapter until Close is called.
type OpenRungWSSResult struct {
	succeeded  bool
	reason     string
	errorText  string
	bridgeHost string
	bridgePort int32
}

func (r *OpenRungWSSResult) Succeeded() bool { return r != nil && r.succeeded }
func (r *OpenRungWSSResult) Reason() string {
	if r == nil {
		return ""
	}
	return r.reason
}
func (r *OpenRungWSSResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.errorText
}
func (r *OpenRungWSSResult) BridgeHost() string {
	if r == nil {
		return ""
	}
	return r.bridgeHost
}
func (r *OpenRungWSSResult) BridgePort() int32 {
	if r == nil {
		return 0
	}
	return r.bridgePort
}

type openRungWSSBridge interface {
	Endpoint() (host string, port int)
	Serve(context.Context) error
	Close() error
}

type openRungWSSDialer func(
	context.Context,
	wsscore.ClientOptions,
) (openRungWSSBridge, error)

func dialOpenRungWSSCore(
	ctx context.Context,
	options wsscore.ClientOptions,
) (openRungWSSBridge, error) {
	// The signed URL and opaque ticket deliberately pass through unchanged.
	// WebSocket, TLS, yamux, copying, and transport bounds stay in wsscore.
	return wsscore.DialClient(ctx, options)
}

func openRungWSSClientOptions(
	frontURL string,
	ticket string,
	protector wsscore.SocketProtector,
) wsscore.ClientOptions {
	return wsscore.ClientOptions{
		URL:    frontURL,
		Ticket: ticket,
		// wsscore applies this only to native one-label *.cloudfront.net URLs.
		// Custom CNAMEs and other CDNs retain ordinary URL-derived SNI, while
		// certificate verification remains bound to the exact signed URL host.
		CloudFrontNoSNI: true,
		SocketProtector: protector,
	}
}

// OpenRungWSSClient owns one in-flight dial and, on success, one live wsscore
// loopback adapter. A ticket is single-use, so Connect may be called only once.
// Close cancels an in-flight dial and synchronously releases an active adapter.
type OpenRungWSSClient struct {
	mu sync.Mutex

	ctx    context.Context
	cancel context.CancelFunc

	frontURL  string
	ticket    string
	protector OpenRungWSSProtector
	listener  OpenRungWSSListener
	// Android must protect every outer socket from VPN recapture. Apple has no
	// VpnService equivalent and deliberately uses wsscore's nil-protector path.
	requireProtector bool

	bridge      openRungWSSBridge
	serveDone   chan struct{}
	attemptDone chan struct{}
	closeDone   chan struct{}
	dial        openRungWSSDialer

	closed    bool
	attempted bool
}

// NewOpenRungWSSClient prepares a single-use, cancelable Android WSS client.
// Connect performs blocking network work and should run on an IO worker.
func NewOpenRungWSSClient(
	frontURL string,
	ticket string,
	protector OpenRungWSSProtector,
	listener OpenRungWSSListener,
) *OpenRungWSSClient {
	return newOpenRungWSSClient(frontURL, ticket, protector, listener, true)
}

// NewOpenRungWSSClientForIOS prepares the same single-use WSS client for
// Apple's Network Extension process. iOS has no Android VpnService socket
// protection API, so this constructor intentionally selects wsscore's
// nil-protector path. The front URL and ticket are still
// passed to wsscore byte-for-byte unchanged.
func NewOpenRungWSSClientForIOS(
	frontURL string,
	ticket string,
	listener OpenRungWSSListener,
) *OpenRungWSSClient {
	return newOpenRungWSSClient(frontURL, ticket, nil, listener, false)
}

func newOpenRungWSSClient(
	frontURL string,
	ticket string,
	protector OpenRungWSSProtector,
	listener OpenRungWSSListener,
	requireProtector bool,
) *OpenRungWSSClient {
	ctx, cancel := context.WithCancel(context.Background())
	return &OpenRungWSSClient{
		ctx:              ctx,
		cancel:           cancel,
		frontURL:         frontURL,
		ticket:           ticket,
		protector:        protector,
		listener:         listener,
		requireProtector: requireProtector,
		closeDone:        make(chan struct{}),
		dial:             dialOpenRungWSSCore,
	}
}

// Connect passes the exact advertised front URL and opaque broker ticket to
// wsscore, starts its loopback server, and returns the endpoint for the existing
// Reality client. Failures are sanitized so credentials never reach UI or logs.
func (c *OpenRungWSSClient) Connect() *OpenRungWSSResult {
	if c == nil {
		return failedOpenRungWSSResult("client")
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return failedOpenRungWSSResult("cancelled")
	}
	if c.attempted {
		c.mu.Unlock()
		return failedOpenRungWSSResult("client")
	}
	c.attempted = true
	c.attemptDone = make(chan struct{})
	attemptDone := c.attemptDone
	ctx := c.ctx
	frontURL := c.frontURL
	ticket := c.ticket
	protector := c.protector
	requireProtector := c.requireProtector
	dial := c.dial
	// Retain credentials only for the duration of this blocking call. A fresh
	// client and a fresh broker ticket are required for every later attempt.
	c.frontURL = ""
	c.ticket = ""
	c.protector = nil
	c.mu.Unlock()
	defer close(attemptDone)

	if requireProtector && protector == nil {
		return failedOpenRungWSSResult("protect")
	}
	if dial == nil {
		return failedOpenRungWSSResult("client")
	}

	var socketProtector wsscore.SocketProtector
	if protector != nil {
		socketProtector = protectedWSSSocket{protector: protector}
	}
	bridge, err := dial(ctx, openRungWSSClientOptions(frontURL, ticket, socketProtector))
	if err != nil {
		return failedOpenRungWSSResult(openRungWSSFailureReason(ctx, err))
	}
	host, port := bridge.Endpoint()
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil || !ip.IsLoopback() || port < 1 || port > 65535 {
		_ = bridge.Close()
		return failedOpenRungWSSResult("adapter")
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		_ = bridge.Close()
		return failedOpenRungWSSResult("cancelled")
	}
	c.bridge = bridge
	c.serveDone = make(chan struct{})
	serveDone := c.serveDone
	// Launch before unlocking so a concurrent Close can safely wait on
	// serveDone without racing a not-yet-started serving goroutine.
	go c.serve(ctx, bridge, serveDone)
	c.mu.Unlock()

	return &OpenRungWSSResult{
		succeeded:  true,
		bridgeHost: ip.String(),
		bridgePort: int32(port),
	}
}

func (c *OpenRungWSSClient) serve(ctx context.Context, bridge openRungWSSBridge, done chan struct{}) {
	_ = bridge.Serve(ctx)
	unexpected := ctx.Err() == nil
	if unexpected {
		_ = bridge.Close()
	}

	c.mu.Lock()
	shouldNotify := unexpected && !c.closed && c.bridge == bridge && c.listener != nil
	listener := c.listener
	if c.bridge == bridge {
		c.bridge = nil
	}
	c.mu.Unlock()

	// Close first so Listener.Closed may call Close without waiting on itself.
	close(done)
	if shouldNotify {
		listener.Closed(unexpectedWSSCloseReason)
	}
}

// Close is idempotent, cancels a blocked Connect, and waits until any in-flight
// dial or serving goroutine has released the wsscore client.
func (c *OpenRungWSSClient) Close() {
	if c == nil {
		return
	}

	c.mu.Lock()
	if c.closed {
		closeDone := c.closeDone
		c.mu.Unlock()
		<-closeDone
		return
	}
	c.closed = true
	c.cancel()
	bridge := c.bridge
	serveDone := c.serveDone
	attemptDone := c.attemptDone
	closeDone := c.closeDone
	c.bridge = nil
	c.frontURL = ""
	c.ticket = ""
	c.protector = nil
	c.listener = nil
	c.mu.Unlock()

	if bridge != nil {
		_ = bridge.Close()
	}
	if serveDone != nil {
		<-serveDone
	}
	if attemptDone != nil {
		<-attemptDone
	}
	close(closeDone)
}

// OpenRungValidateWSSFronts validates an advertised JSON front array with
// wsscore and additionally requires the advertised values and order to already
// equal wsscore's canonical, ID-sorted result. It never rewrites signed input.
func OpenRungValidateWSSFronts(frontsJSON string) bool {
	decoder := json.NewDecoder(strings.NewReader(frontsJSON))
	decoder.DisallowUnknownFields()
	var fronts []wsscore.Front
	if err := decoder.Decode(&fronts); err != nil || len(fronts) == 0 {
		return false
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return false
	}
	normalized, err := wsscore.NormalizeFronts(fronts)
	return err == nil && slices.Equal(normalized, fronts)
}

type protectedWSSSocket struct {
	protector OpenRungWSSProtector
}

func (p protectedWSSSocket) Protect(fd int32) (allowed bool) {
	if p.protector == nil {
		return false
	}
	// A broken Java/Kotlin implementation, including a typed-nil proxy, must
	// fail closed rather than escaping protection through a panic.
	defer func() {
		if recover() != nil {
			allowed = false
		}
	}()
	return p.protector.Protect(fd)
}

func openRungWSSFailureReason(ctx context.Context, err error) string {
	if ctx.Err() != nil || errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, wsscore.ErrSocketProtectionFailed) {
		return "protect"
	}
	if errors.Is(err, wsscore.ErrInvalidFront) {
		return "front"
	}
	return "transport"
}

func failedOpenRungWSSResult(reason string) *OpenRungWSSResult {
	message := "WSS connection failed"
	switch reason {
	case "protect":
		message = "VPN socket protection failed"
	case "cancelled":
		message = "WSS connection cancelled"
	case "front":
		message = "Invalid WSS front"
	case "adapter":
		message = "Invalid WSS loopback endpoint"
	case "client":
		message = "WSS client is unavailable"
	}
	return &OpenRungWSSResult{reason: reason, errorText: message}
}
