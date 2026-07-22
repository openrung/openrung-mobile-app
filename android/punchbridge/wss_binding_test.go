package libbox

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/openrung/openrung/wsscore"
)

const (
	testWSSFrontURL = "wss://d111111abcdef8.cloudfront.net/api/v1/wss-bridge"
	testWSSTicket   = "opaque-single-use-ticket"
)

type testWSSProtector struct {
	allow  bool
	calls  atomic.Int32
	lastFD atomic.Int32
}

func (p *testWSSProtector) Protect(fd int32) bool {
	p.calls.Add(1)
	p.lastFD.Store(fd)
	return p.allow
}

type panicWSSProtector struct{}

func (panicWSSProtector) Protect(int32) bool {
	panic("broken platform protector")
}

type testWSSListener struct {
	closed chan string
}

func (l *testWSSListener) Closed(reason string) {
	select {
	case l.closed <- reason:
	default:
	}
}

type testWSSBridge struct {
	host string
	port int

	serveStarted chan struct{}
	stop         chan struct{}
	stopOnce     sync.Once
	closeCalls   atomic.Int32
	serveErr     error
}

func newTestWSSBridge() *testWSSBridge {
	return &testWSSBridge{
		host:         "127.0.0.1",
		port:         31337,
		serveStarted: make(chan struct{}),
		stop:         make(chan struct{}),
	}
}

func (b *testWSSBridge) Endpoint() (string, int) { return b.host, b.port }

func (b *testWSSBridge) Serve(ctx context.Context) error {
	close(b.serveStarted)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-b.stop:
		return b.serveErr
	}
}

func (b *testWSSBridge) Close() error {
	b.closeCalls.Add(1)
	b.stopOnce.Do(func() { close(b.stop) })
	return nil
}

func (b *testWSSBridge) fail(err error) {
	b.serveErr = err
	b.stopOnce.Do(func() { close(b.stop) })
}

func TestOpenRungWSSCoreOptionsEnableCloudFrontNoSNIWithoutChangingCredentials(t *testing.T) {
	protector := &testWSSProtector{allow: true}
	options := openRungWSSClientOptions(testWSSFrontURL, testWSSTicket, protector)
	if options.URL != testWSSFrontURL || options.Ticket != testWSSTicket {
		t.Fatalf("credentials changed: URL=%q ticket=%q", options.URL, options.Ticket)
	}
	if !options.CloudFrontNoSNI {
		t.Fatal("CloudFront no-SNI mode was not enabled")
	}
	if options.SocketProtector != protector {
		t.Fatal("CloudFront no-SNI mode did not preserve the selected socket protector")
	}
}

func TestOpenRungWSSConnectPassesExactCredentialsAndCleansUp(t *testing.T) {
	protector := &testWSSProtector{allow: true}
	listener := &testWSSListener{closed: make(chan string, 1)}
	bridge := newTestWSSBridge()
	client := NewOpenRungWSSClient(testWSSFrontURL, testWSSTicket, protector, listener)
	client.dial = func(
		_ context.Context,
		options wsscore.ClientOptions,
	) (openRungWSSBridge, error) {
		if options.URL != testWSSFrontURL || options.Ticket != testWSSTicket {
			t.Fatalf("credentials changed: URL=%q ticket=%q", options.URL, options.Ticket)
		}
		if !options.CloudFrontNoSNI {
			t.Fatal("CloudFront no-SNI mode was not enabled")
		}
		if !options.SocketProtector.Protect(91) {
			t.Fatal("allowed VpnService protector was rejected")
		}
		return bridge, nil
	}

	result := client.Connect()
	if !result.Succeeded() || result.BridgeHost() != "127.0.0.1" || result.BridgePort() != 31337 {
		t.Fatalf("Connect result = success:%v endpoint:%s:%d reason:%q", result.Succeeded(), result.BridgeHost(), result.BridgePort(), result.Reason())
	}
	<-bridge.serveStarted
	if protector.calls.Load() != 1 || protector.lastFD.Load() != 91 {
		t.Fatalf("protector calls=%d fd=%d", protector.calls.Load(), protector.lastFD.Load())
	}

	var closes sync.WaitGroup
	closes.Add(2)
	go func() { defer closes.Done(); client.Close() }()
	go func() { defer closes.Done(); client.Close() }()
	closes.Wait()
	if bridge.closeCalls.Load() != 1 {
		t.Fatalf("bridge Close calls = %d, want 1", bridge.closeCalls.Load())
	}
	select {
	case reason := <-listener.closed:
		t.Fatalf("explicit Close emitted listener callback %q", reason)
	default:
	}
}

func TestOpenRungWSSIOSConnectUsesNilProtectorAndExactCredentials(t *testing.T) {
	bridge := newTestWSSBridge()
	// A nil listener is valid on iOS; lifecycle cleanup must not depend on a
	// callback implementation being present.
	client := NewOpenRungWSSClientForIOS(testWSSFrontURL, testWSSTicket, nil)
	client.dial = func(
		_ context.Context,
		options wsscore.ClientOptions,
	) (openRungWSSBridge, error) {
		if options.URL != testWSSFrontURL || options.Ticket != testWSSTicket {
			t.Fatalf("credentials changed: URL=%q ticket=%q", options.URL, options.Ticket)
		}
		if !options.CloudFrontNoSNI {
			t.Fatal("CloudFront no-SNI mode was not enabled for iOS")
		}
		if options.SocketProtector != nil {
			t.Fatal("iOS constructor installed an Android SocketProtector")
		}
		return bridge, nil
	}

	result := client.Connect()
	if !result.Succeeded() || result.BridgeHost() != "127.0.0.1" || result.BridgePort() != 31337 {
		t.Fatalf("Connect result = success:%v endpoint:%s:%d reason:%q", result.Succeeded(), result.BridgeHost(), result.BridgePort(), result.Reason())
	}
	<-bridge.serveStarted
	client.Close()
	if bridge.closeCalls.Load() != 1 {
		t.Fatalf("bridge Close calls = %d, want 1", bridge.closeCalls.Load())
	}
}

func TestOpenRungWSSNoSNIFailureDoesNotRetryTicketWithSNI(t *testing.T) {
	client := NewOpenRungWSSClient(
		testWSSFrontURL,
		testWSSTicket,
		&testWSSProtector{allow: true},
		nil,
	)
	var calls atomic.Int32
	client.dial = func(_ context.Context, options wsscore.ClientOptions) (openRungWSSBridge, error) {
		calls.Add(1)
		if !options.CloudFrontNoSNI {
			t.Fatal("ambiguous handshake was retried without CloudFront no-SNI mode")
		}
		return nil, errors.New("ambiguous WSS handshake failure")
	}

	first := client.Connect()
	second := client.Connect()
	client.Close()
	if first.Succeeded() || first.Reason() != "transport" {
		t.Fatalf("first Connect = success:%v reason:%q", first.Succeeded(), first.Reason())
	}
	if second.Succeeded() || second.Reason() != "client" {
		t.Fatalf("second Connect = success:%v reason:%q", second.Succeeded(), second.Reason())
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("dial calls = %d, want one no-downgrade attempt", got)
	}
}

func TestOpenRungWSSProtectionFailsClosed(t *testing.T) {
	t.Run("nil", func(t *testing.T) {
		client := NewOpenRungWSSClient(testWSSFrontURL, testWSSTicket, nil, nil)
		var dialed atomic.Bool
		client.dial = func(context.Context, wsscore.ClientOptions) (openRungWSSBridge, error) {
			dialed.Store(true)
			return nil, errors.New("must not dial")
		}
		result := client.Connect()
		client.Close()
		if result.Succeeded() || result.Reason() != "protect" || dialed.Load() {
			t.Fatalf("nil protector result = success:%v reason:%q dialed:%v", result.Succeeded(), result.Reason(), dialed.Load())
		}
	})

	t.Run("false", func(t *testing.T) {
		protector := &testWSSProtector{allow: false}
		client := NewOpenRungWSSClient(testWSSFrontURL, testWSSTicket, protector, nil)
		client.dial = func(
			_ context.Context,
			options wsscore.ClientOptions,
		) (openRungWSSBridge, error) {
			if options.SocketProtector.Protect(92) {
				return nil, errors.New("denied protector returned true")
			}
			return nil, wsscore.ErrSocketProtectionFailed
		}
		result := client.Connect()
		client.Close()
		if result.Succeeded() || result.Reason() != "protect" {
			t.Fatalf("false protector result = success:%v reason:%q", result.Succeeded(), result.Reason())
		}
		if protector.calls.Load() != 1 || protector.lastFD.Load() != 92 {
			t.Fatalf("protector calls=%d fd=%d", protector.calls.Load(), protector.lastFD.Load())
		}
	})

	t.Run("panic", func(t *testing.T) {
		client := NewOpenRungWSSClient(testWSSFrontURL, testWSSTicket, panicWSSProtector{}, nil)
		client.dial = func(
			_ context.Context,
			options wsscore.ClientOptions,
		) (openRungWSSBridge, error) {
			if options.SocketProtector.Protect(93) {
				return nil, errors.New("panicking protector returned true")
			}
			return nil, wsscore.ErrSocketProtectionFailed
		}
		result := client.Connect()
		client.Close()
		if result.Succeeded() || result.Reason() != "protect" {
			t.Fatalf("panicking protector result = success:%v reason:%q", result.Succeeded(), result.Reason())
		}
	})
}

func TestOpenRungWSSCloseCancelsBlockedConnectWithoutLeakingSecrets(t *testing.T) {
	client := NewOpenRungWSSClient(testWSSFrontURL, testWSSTicket, &testWSSProtector{allow: true}, nil)
	dialStarted := make(chan struct{})
	client.dial = func(ctx context.Context, options wsscore.ClientOptions) (openRungWSSBridge, error) {
		close(dialStarted)
		<-ctx.Done()
		return nil, fmt.Errorf("dial %s with %s: %w", options.URL, options.Ticket, ctx.Err())
	}

	resultChannel := make(chan *OpenRungWSSResult, 1)
	go func() { resultChannel <- client.Connect() }()
	<-dialStarted
	client.Close()
	result := <-resultChannel
	if result.Succeeded() || result.Reason() != "cancelled" {
		t.Fatalf("cancelled result = success:%v reason:%q", result.Succeeded(), result.Reason())
	}
	if strings.Contains(result.ErrorText(), testWSSFrontURL) || strings.Contains(result.ErrorText(), testWSSTicket) {
		t.Fatalf("sanitized error leaked credentials: %q", result.ErrorText())
	}
}

func TestOpenRungWSSIOSCloseCancelsBlockedConnect(t *testing.T) {
	client := NewOpenRungWSSClientForIOS(testWSSFrontURL, testWSSTicket, nil)
	dialStarted := make(chan struct{})
	client.dial = func(ctx context.Context, options wsscore.ClientOptions) (openRungWSSBridge, error) {
		if options.SocketProtector != nil {
			t.Error("iOS cancellation dial received an Android SocketProtector")
		}
		close(dialStarted)
		<-ctx.Done()
		return nil, ctx.Err()
	}

	resultChannel := make(chan *OpenRungWSSResult, 1)
	go func() { resultChannel <- client.Connect() }()
	<-dialStarted

	var closes sync.WaitGroup
	closes.Add(2)
	go func() { defer closes.Done(); client.Close() }()
	go func() { defer closes.Done(); client.Close() }()
	closes.Wait()

	result := <-resultChannel
	if result.Succeeded() || result.Reason() != "cancelled" {
		t.Fatalf("cancelled result = success:%v reason:%q", result.Succeeded(), result.Reason())
	}
}

func TestOpenRungWSSUnexpectedServeExitIsSanitized(t *testing.T) {
	const serveSecret = "secret-ticket-from-server-error"
	listener := &testWSSListener{closed: make(chan string, 1)}
	bridge := newTestWSSBridge()
	client := NewOpenRungWSSClient(testWSSFrontURL, testWSSTicket, &testWSSProtector{allow: true}, listener)
	client.dial = func(context.Context, wsscore.ClientOptions) (openRungWSSBridge, error) {
		return bridge, nil
	}
	if result := client.Connect(); !result.Succeeded() {
		t.Fatalf("Connect failed: %s", result.ErrorText())
	}
	<-bridge.serveStarted
	bridge.fail(errors.New(serveSecret))
	reason := <-listener.closed
	if reason != unexpectedWSSCloseReason || strings.Contains(reason, serveSecret) || strings.Contains(reason, testWSSTicket) {
		t.Fatalf("listener reason was not sanitized: %q", reason)
	}
	client.Close()
}

func TestOpenRungValidateWSSFrontsRequiresCanonicalAdvertisedOrder(t *testing.T) {
	frontA := `{"id":"front-a","url":"wss://d111111abcdef8.cloudfront.net/api/v1/wss-bridge","protocol_version":1}`
	frontB := `{"id":"front-b","url":"wss://d222222abcdef8.cloudfront.net/api/v1/wss-bridge","protocol_version":1}`
	for name, test := range map[string]struct {
		json string
		want bool
	}{
		"canonical":      {json: `[` + frontA + `,` + frontB + `]`, want: true},
		"unsorted":       {json: `[` + frontB + `,` + frontA + `]`},
		"noncanonical":   {json: `[{"id":"Front-A","url":"WSS://D111111ABCDEF8.CLOUDFRONT.NET/api/v1/wss-bridge","protocol_version":1}]`},
		"wrong protocol": {json: `[{"id":"front-a","url":"wss://d111111abcdef8.cloudfront.net/api/v1/wss-bridge","protocol_version":2}]`},
		"duplicate ID":   {json: `[` + frontA + `,` + frontA + `]`},
		"duplicate URL":  {json: `[` + frontA + `,{"id":"front-b","url":"wss://d111111abcdef8.cloudfront.net/api/v1/wss-bridge","protocol_version":1}]`},
		"unknown field":  {json: `[{"id":"front-a","url":"wss://d111111abcdef8.cloudfront.net/api/v1/wss-bridge","protocol_version":1,"ticket":"secret"}]`},
		"empty":          {json: `[]`},
		"trailing":       {json: `[` + frontA + `] true`},
	} {
		t.Run(name, func(t *testing.T) {
			if got := OpenRungValidateWSSFronts(test.json); got != test.want {
				t.Fatalf("OpenRungValidateWSSFronts(%s) = %v, want %v", test.json, got, test.want)
			}
		})
	}
}
