package libbox

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openrung/openrung/brokerapi"
)

type testOpenRungBrokerClient struct {
	firstReachable func(
		context.Context,
		brokerapi.Candidates,
		brokerapi.ListOptions,
	) (brokerapi.Fetch, error)
	sendTelemetry func(context.Context, string, []byte) error
	requestTicket func(
		context.Context,
		string,
		brokerapi.WSSTicketRequest,
	) (brokerapi.WSSTicketResponse, error)
	runSpeedTest      func(context.Context, string) (brokerapi.SpeedTestResult, error)
	downloadSpeedTest func(context.Context, string, int) (brokerapi.SpeedTestResult, error)
}

func (c *testOpenRungBrokerClient) FirstReachable(
	ctx context.Context,
	candidates brokerapi.Candidates,
	options brokerapi.ListOptions,
) (brokerapi.Fetch, error) {
	if c.firstReachable == nil {
		return brokerapi.Fetch{}, errors.New("unexpected FirstReachable call")
	}
	return c.firstReachable(ctx, candidates, options)
}

func (c *testOpenRungBrokerClient) SendTelemetryBatchJSON(
	ctx context.Context,
	brokerURL string,
	body []byte,
) error {
	if c.sendTelemetry == nil {
		return errors.New("unexpected SendTelemetryBatchJSON call")
	}
	return c.sendTelemetry(ctx, brokerURL, body)
}

func (c *testOpenRungBrokerClient) RequestWSSTicket(
	ctx context.Context,
	brokerURL string,
	request brokerapi.WSSTicketRequest,
) (brokerapi.WSSTicketResponse, error) {
	if c.requestTicket == nil {
		return brokerapi.WSSTicketResponse{}, errors.New("unexpected RequestWSSTicket call")
	}
	return c.requestTicket(ctx, brokerURL, request)
}

func (c *testOpenRungBrokerClient) RunSpeedTest(
	ctx context.Context,
	brokerURL string,
) (brokerapi.SpeedTestResult, error) {
	if c.runSpeedTest == nil {
		return brokerapi.SpeedTestResult{}, errors.New("unexpected RunSpeedTest call")
	}
	return c.runSpeedTest(ctx, brokerURL)
}

func (c *testOpenRungBrokerClient) DownloadSpeedTest(
	ctx context.Context,
	brokerURL string,
	byteCount int,
) (brokerapi.SpeedTestResult, error) {
	if c.downloadSpeedTest == nil {
		return brokerapi.SpeedTestResult{}, errors.New("unexpected DownloadSpeedTest call")
	}
	return c.downloadSpeedTest(ctx, brokerURL, byteCount)
}

func openRungBrokerImplementation(
	t *testing.T,
	operation OpenRungBrokerOperation,
) *openRungBrokerOperation {
	t.Helper()
	implementation, ok := operation.(*openRungBrokerOperation)
	if !ok {
		t.Fatalf("operation implementation = %T", operation)
	}
	return implementation
}

func validOpenRungTelemetryBatch(clientID, sessionID string) string {
	return fmt.Sprintf(
		`{"events":[{"schema_version":1,"event_id":"event-1","event":"connected",`+
			`"occurred_at":"2026-07-24T00:00:00Z","client_id":%q,"session_id":%q}]}`,
		clientID,
		sessionID,
	)
}

func validLoopbackRelayJSON() string {
	return `{"count":0,"server_time":"2026-07-24T00:00:00Z","relays":[]}`
}

func TestOpenRungBrokerConstructorsEmitFixedPlatformHeaders(t *testing.T) {
	tests := []struct {
		name             string
		newOperation     func() OpenRungBrokerOperation
		wantHeader       string
		wantHeaderValue  string
		forbiddenHeaders []string
	}{
		{
			name:            "android",
			newOperation:    func() OpenRungBrokerOperation { return NewOpenRungBrokerOperationForAndroid(" 1.2.3 ", " 35 ") },
			wantHeader:      "X-OpenRung-Android-API",
			wantHeaderValue: "35",
			forbiddenHeaders: []string{
				"X-OpenRung-iOS-Version",
				"X-OpenRung-RN",
			},
		},
		{
			name:            "ios",
			newOperation:    func() OpenRungBrokerOperation { return NewOpenRungBrokerOperationForIOS(" 1.2.3 ", " 18.5 ") },
			wantHeader:      "X-OpenRung-iOS-Version",
			wantHeaderValue: "18.5",
			forbiddenHeaders: []string{
				"X-OpenRung-Android-API",
				"X-OpenRung-RN",
			},
		},
		{
			name:            "react-native",
			newOperation:    func() OpenRungBrokerOperation { return NewOpenRungBrokerOperationForReactNative(" 1.2.3 ", " ios ") },
			wantHeader:      "X-OpenRung-RN",
			wantHeaderValue: "ios",
			forbiddenHeaders: []string{
				"X-OpenRung-Android-API",
				"X-OpenRung-iOS-Version",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				if request.URL.Path != "/api/v1/speed-test" ||
					request.URL.Query().Get("bytes") != "1" {
					t.Errorf("speed request URL = %s", request.URL.String())
				}
				if got := request.Header.Get("X-OpenRung-App-Version"); got != "1.2.3" {
					t.Errorf("app version header = %q", got)
				}
				if got := request.Header.Get(test.wantHeader); got != test.wantHeaderValue {
					t.Errorf("%s = %q, want %q", test.wantHeader, got, test.wantHeaderValue)
				}
				for _, forbidden := range test.forbiddenHeaders {
					if got := request.Header.Get(forbidden); got != "" {
						t.Errorf("unexpected %s = %q", forbidden, got)
					}
				}
				_, _ = io.WriteString(response, "x")
			}))
			defer server.Close()

			operation := test.newOperation()
			result := operation.DownloadSpeedTest(server.URL, 1)
			operation.Close()
			if !result.Succeeded() || result.Bytes() != 1 {
				t.Fatalf(
					"speed result = success:%v kind:%q text:%q bytes:%d",
					result.Succeeded(),
					result.ErrorKind(),
					result.ErrorText(),
					result.Bytes(),
				)
			}
		})
	}
}

func TestOpenRungBrokerReactNativePlatformIsOneStringEnum(t *testing.T) {
	operation := NewOpenRungBrokerOperationForReactNative("1.2.3", "android")
	implementation := openRungBrokerImplementation(t, operation)
	defer operation.Close()
	if implementation.options.Platform != brokerapi.PlatformReactNative {
		t.Fatalf("platform = %q", implementation.options.Platform)
	}
	if implementation.options.Platform == brokerapi.PlatformAndroid ||
		implementation.options.Platform == brokerapi.PlatformIOS {
		t.Fatalf("React Native operation selected native platform %q", implementation.options.Platform)
	}
}

func TestOpenRungDefaultBrokerURLsJSON(t *testing.T) {
	const want = `["https://broker.openrung.org/","https://d2r7mdpyevvs1m.cloudfront.net/"]`
	if got := OpenRungDefaultBrokerURLsJSON(); got != want {
		t.Fatalf("OpenRungDefaultBrokerURLsJSON() = %q, want %q", got, want)
	}
}

func TestOpenRungFirstReachableUsesBrokerapiCandidatePolicy(t *testing.T) {
	operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
	implementation := openRungBrokerImplementation(t, operation)
	var gotCandidates brokerapi.Candidates
	var gotOptions brokerapi.ListOptions
	implementation.client = &testOpenRungBrokerClient{
		firstReachable: func(
			_ context.Context,
			candidates brokerapi.Candidates,
			options brokerapi.ListOptions,
		) (brokerapi.Fetch, error) {
			gotCandidates = candidates
			gotOptions = options
			return brokerapi.Fetch{}, &brokerapi.BrokerStatusError{StatusCode: http.StatusBadGateway}
		},
	}

	result := operation.FirstReachable(
		" https://custom.example/ ",
		9,
		"client-a",
		"session-a",
	)
	operation.Close()
	if result.Succeeded() || result.ErrorKind() != "http_status" || result.HTTPStatus() != 502 {
		t.Fatalf(
			"result = success:%v kind:%q status:%d",
			result.Succeeded(),
			result.ErrorKind(),
			result.HTTPStatus(),
		)
	}
	wantCandidates := brokerapi.BrokerCandidates(" https://custom.example/ ")
	if !reflect.DeepEqual(gotCandidates, wantCandidates) {
		t.Fatalf("candidates = %+v, want %+v", gotCandidates, wantCandidates)
	}
	if !gotCandidates.OverrideFirst ||
		!reflect.DeepEqual(gotCandidates.URLs, []string{
			"https://custom.example/",
			brokerapi.DefaultBrokerURL,
			brokerapi.CloudFrontBrokerURL,
		}) {
		t.Fatalf("custom candidate policy = %+v", gotCandidates)
	}
	if gotOptions.Limit != 9 ||
		gotOptions.Identity.ClientID != "client-a" ||
		gotOptions.Identity.SessionID != "session-a" ||
		gotOptions.Stagger != 0 {
		t.Fatalf("list options = %+v", gotOptions)
	}
}

func TestOpenRungFirstReachablePreservesDefaultCandidatePolicy(t *testing.T) {
	for _, primary := range []string{
		"",
		brokerapi.DefaultBrokerURL,
		brokerapi.CloudFrontBrokerURL,
	} {
		t.Run(primary, func(t *testing.T) {
			operation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
			implementation := openRungBrokerImplementation(t, operation)
			var got brokerapi.Candidates
			implementation.client = &testOpenRungBrokerClient{
				firstReachable: func(
					_ context.Context,
					candidates brokerapi.Candidates,
					_ brokerapi.ListOptions,
				) (brokerapi.Fetch, error) {
					got = candidates
					return brokerapi.Fetch{}, errors.New("stop after capturing candidates")
				},
			}
			_ = operation.FirstReachable(primary, 5, "", "")
			operation.Close()
			want := brokerapi.BrokerCandidates(primary)
			if !reflect.DeepEqual(got, want) || got.OverrideFirst {
				t.Fatalf("candidates for %q = %+v, want %+v", primary, got, want)
			}
		})
	}
}

func TestOpenRungFirstReachableForwardsVerifiedMetadata(t *testing.T) {
	operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
	implementation := openRungBrokerImplementation(t, operation)
	implementation.client = &testOpenRungBrokerClient{
		firstReachable: func(
			context.Context,
			brokerapi.Candidates,
			brokerapi.ListOptions,
		) (brokerapi.Fetch, error) {
			return brokerapi.Fetch{
				BrokerURL: "https://broker.openrung.org/",
				RelayList: brokerapi.RelayList{
					KeyID:             "production-key",
					SignatureVerified: true,
				},
			}, nil
		},
	}
	result := operation.FirstReachable("", 5, "", "")
	operation.Close()
	if !result.Succeeded() ||
		result.KeyID() != "production-key" ||
		!result.SignatureVerified() {
		t.Fatalf(
			"verified metadata = success:%v key:%q verified:%v",
			result.Succeeded(),
			result.KeyID(),
			result.SignatureVerified(),
		)
	}
}

func TestOpenRungFirstReachableReturnsExactLoopbackBytesAndPairedIdentity(t *testing.T) {
	for _, test := range []struct {
		name        string
		clientID    string
		sessionID   string
		wantHeaders bool
	}{
		{name: "paired", clientID: "client-a", sessionID: "session-a", wantHeaders: true},
		{name: "missing client", sessionID: "session-a"},
		{name: "missing session", clientID: "client-a"},
	} {
		t.Run(test.name, func(t *testing.T) {
			const relayJSON = " \n" +
				`{"count":0,"server_time":"2026-07-24T00:00:00Z","relays":[]}` +
				"\n"
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				if request.URL.Path != "/api/v1/relays" ||
					request.URL.Query().Get("limit") != "7" {
					t.Errorf("relay URL = %s", request.URL.String())
				}
				if test.wantHeaders {
					if request.Header.Get("X-OpenRung-Client-ID") != test.clientID ||
						request.Header.Get("X-OpenRung-Session-ID") != test.sessionID {
						t.Errorf("paired identity headers = %v", request.Header)
					}
				} else if request.Header.Get("X-OpenRung-Client-ID") != "" ||
					request.Header.Get("X-OpenRung-Session-ID") != "" {
					t.Errorf("half identity escaped in headers: %v", request.Header)
				}
				_, _ = io.WriteString(response, relayJSON)
			}))
			defer server.Close()

			operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
			result := operation.FirstReachable(
				server.URL,
				7,
				test.clientID,
				test.sessionID,
			)
			operation.Close()
			if !result.Succeeded() {
				t.Fatalf("FirstReachable failed: %s (%s)", result.ErrorText(), result.ErrorKind())
			}
			if result.BrokerURL() != server.URL || result.RelayJSON() != relayJSON {
				t.Fatalf("relay result = broker:%q JSON:%q", result.BrokerURL(), result.RelayJSON())
			}
			if result.KeyID() != "" || result.SignatureVerified() {
				t.Fatalf(
					"loopback signature metadata = key:%q verified:%v",
					result.KeyID(),
					result.SignatureVerified(),
				)
			}
		})
	}
}

func TestOpenRungFirstReachableRejectsInvalidUTF8(t *testing.T) {
	body := append(
		[]byte(`{"count":0,"server_time":"2026-07-24T00:00:00Z","relays":[],"extra":"`),
		0xff,
	)
	body = append(body, []byte(`"}`)...)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = response.Write(body)
	}))
	defer server.Close()

	operation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
	result := operation.FirstReachable(server.URL, 5, "", "")
	operation.Close()
	if result.Succeeded() || result.ErrorKind() != "verification" || result.RelayJSON() != "" {
		t.Fatalf(
			"invalid UTF-8 result = success:%v kind:%q JSON:%q",
			result.Succeeded(),
			result.ErrorKind(),
			result.RelayJSON(),
		)
	}
}

func TestOpenRungTelemetryUsesBrokerapiValidationAndPairedIdentity(t *testing.T) {
	requestBody := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/api/v1/telemetry/events" {
			t.Errorf("telemetry request = %s %s", request.Method, request.URL.String())
		}
		if request.Header.Get("X-OpenRung-Client-ID") != "client-a" ||
			request.Header.Get("X-OpenRung-Session-ID") != "session-a" {
			t.Errorf("telemetry identity headers = %v", request.Header)
		}
		body, _ := io.ReadAll(request.Body)
		requestBody <- string(body)
		response.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	batch := strings.Replace(
		validOpenRungTelemetryBatch("client-a", "session-a"),
		`"session_id":"session-a"`,
		`"session_id":"session-a","destination_address":"private.example"`,
		1,
	)
	operation := NewOpenRungBrokerOperationForReactNative("1.2.3", "ios")
	result := operation.SendTelemetryBatchJSON(server.URL, batch)
	operation.Close()
	if !result.Succeeded() {
		t.Fatalf("telemetry failed: %s (%s)", result.ErrorText(), result.ErrorKind())
	}
	sent := <-requestBody
	if strings.Contains(sent, "destination_address") ||
		strings.Contains(sent, "private.example") {
		t.Fatalf("brokerapi did not scrub legacy destination fields: %s", sent)
	}

	for name, invalid := range map[string]string{
		"invalid JSON": `{"events":[`,
		"multiple values": validOpenRungTelemetryBatch("client-a", "session-a") +
			` true`,
		"mixed identities": `{"events":[` +
			strings.TrimSuffix(
				strings.TrimPrefix(validOpenRungTelemetryBatch("a", "one"), `{"events":[`),
				`]}`,
			) +
			`,` +
			strings.TrimSuffix(
				strings.TrimPrefix(validOpenRungTelemetryBatch("b", "two"), `{"events":[`),
				`]}`,
			) +
			`]}`,
	} {
		t.Run(name, func(t *testing.T) {
			operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
			result := operation.SendTelemetryBatchJSON(server.URL, invalid)
			operation.Close()
			if result.Succeeded() || result.ErrorKind() != "validation" {
				t.Fatalf(
					"invalid telemetry = success:%v kind:%q text:%q",
					result.Succeeded(),
					result.ErrorKind(),
					result.ErrorText(),
				)
			}
		})
	}
}

func TestOpenRungWSSTicketGettersAndFormattedOutputAreRedacted(t *testing.T) {
	const ticket = "opaque-single-use-ticket"
	ticketURL := "wss://front.example/api/v1/wss-bridge?ticket=" + ticket
	expiresAt := time.Now().Add(time.Hour).UTC().Truncate(time.Millisecond)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/api/v1/wss/tickets" {
			t.Errorf("ticket request = %s %s", request.Method, request.URL.String())
		}
		if request.Header.Get("X-OpenRung-Client-ID") != "client-a" ||
			request.Header.Get("X-OpenRung-Session-ID") != "session-a" {
			t.Errorf("ticket identity headers = %v", request.Header)
		}
		var payload map[string]string
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Errorf("decode ticket request: %v", err)
		}
		if !reflect.DeepEqual(payload, map[string]string{
			"relay_id": "relay-a",
			"front_id": "front-a",
		}) {
			t.Errorf("ticket payload = %#v", payload)
		}
		_ = json.NewEncoder(response).Encode(map[string]string{
			"ticket":     ticket,
			"url":        ticketURL,
			"expires_at": expiresAt.Format(time.RFC3339Nano),
		})
	}))
	defer server.Close()

	operation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
	result := operation.RequestWSSTicket(
		server.URL,
		"relay-a",
		"front-a",
		"client-a",
		"session-a",
	)
	operation.Close()
	if !result.Succeeded() ||
		result.Ticket() != ticket ||
		result.URL() != ticketURL ||
		result.ExpiresAtMillis() != expiresAt.UnixMilli() {
		t.Fatalf(
			"ticket result = success:%v ticket:%q URL:%q expiry:%d kind:%q",
			result.Succeeded(),
			result.Ticket(),
			result.URL(),
			result.ExpiresAtMillis(),
			result.ErrorKind(),
		)
	}
	for name, formatted := range map[string]string{
		"pointer String":   fmt.Sprintf("%v", result),
		"pointer detailed": fmt.Sprintf("%+v", result),
		"pointer GoString": fmt.Sprintf("%#v", result),
		"value String":     fmt.Sprintf("%v", *result),
		"value detailed":   fmt.Sprintf("%+v", *result),
		"value GoString":   fmt.Sprintf("%#v", *result),
		"ErrorText":        result.ErrorText(),
	} {
		if strings.Contains(formatted, ticket) || strings.Contains(formatted, ticketURL) {
			t.Fatalf("%s leaked WSS credentials: %q", name, formatted)
		}
	}
}

func TestOpenRungWSSTicketStatusIsBoundedAndNeverIncludesResponse(t *testing.T) {
	const secret = "server-body-with-secret-ticket"
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Retry-After", "3")
		response.WriteHeader(http.StatusTooManyRequests)
		_, _ = io.WriteString(response, strings.Repeat(secret, 1024))
	}))
	defer server.Close()

	operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
	result := operation.RequestWSSTicket(server.URL, "relay-a", "front-a", "", "")
	operation.Close()
	if result.Succeeded() ||
		result.ErrorKind() != "rate_limited" ||
		result.HTTPStatus() != http.StatusTooManyRequests ||
		result.RetryAfterMillis() != 3000 {
		t.Fatalf(
			"status result = success:%v kind:%q status:%d retry:%d",
			result.Succeeded(),
			result.ErrorKind(),
			result.HTTPStatus(),
			result.RetryAfterMillis(),
		)
	}
	if strings.Contains(result.ErrorText(), secret) || len(result.ErrorText()) > 256 {
		t.Fatalf("unsafe ErrorText = %q", result.ErrorText())
	}
}

func TestOpenRungSpeedResultsPreserveBrokerapiSemantics(t *testing.T) {
	const brokerURL = "https://broker.openrung.org/"
	want := brokerapi.SpeedTestResult{
		Bytes:            10_000_000,
		TTFB:             1250 * time.Millisecond,
		DownloadDuration: 2 * time.Second,
		TotalDuration:    3250 * time.Millisecond,
		// Deliberately inconsistent with Bytes/TotalDuration: the binding must
		// preserve brokerapi's value instead of recomputing with another field.
		MegabitsPerSecond: 123.456789,
	}
	operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
	implementation := openRungBrokerImplementation(t, operation)
	implementation.client = &testOpenRungBrokerClient{
		runSpeedTest: func(_ context.Context, gotBrokerURL string) (brokerapi.SpeedTestResult, error) {
			if gotBrokerURL != brokerURL {
				t.Errorf("broker URL = %q", gotBrokerURL)
			}
			return want, nil
		},
	}
	result := operation.RunSpeedTest(brokerURL)
	operation.Close()
	if !result.Succeeded() ||
		result.Bytes() != want.Bytes ||
		result.TTFBMillis() != 1250 ||
		result.DownloadDurationMillis() != 2000 ||
		result.TotalDurationMillis() != 3250 ||
		result.Mbps() != want.MegabitsPerSecond {
		t.Fatalf(
			"speed result = success:%v bytes:%d ttfb:%d download:%d total:%d mbps:%f",
			result.Succeeded(),
			result.Bytes(),
			result.TTFBMillis(),
			result.DownloadDurationMillis(),
			result.TotalDurationMillis(),
			result.Mbps(),
		)
	}

	downloadOperation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
	downloadImplementation := openRungBrokerImplementation(t, downloadOperation)
	downloadImplementation.client = &testOpenRungBrokerClient{
		downloadSpeedTest: func(
			_ context.Context,
			gotBrokerURL string,
			byteCount int,
		) (brokerapi.SpeedTestResult, error) {
			if gotBrokerURL != brokerURL || byteCount != 1234 {
				t.Errorf("DownloadSpeedTest(%q, %d)", gotBrokerURL, byteCount)
			}
			return brokerapi.SpeedTestResult{Bytes: int64(byteCount)}, nil
		},
	}
	download := downloadOperation.DownloadSpeedTest(brokerURL, 1234)
	downloadOperation.Close()
	if !download.Succeeded() || download.Bytes() != 1234 {
		t.Fatalf("download result = success:%v bytes:%d", download.Succeeded(), download.Bytes())
	}
}

func TestOpenRungBrokerOperationIsSingleUseAndCloseCancels(t *testing.T) {
	operation := NewOpenRungBrokerOperationForAndroid("1.2.3", "35")
	implementation := openRungBrokerImplementation(t, operation)
	started := make(chan struct{})
	var calls atomic.Int32
	implementation.client = &testOpenRungBrokerClient{
		sendTelemetry: func(ctx context.Context, _ string, _ []byte) error {
			calls.Add(1)
			close(started)
			<-ctx.Done()
			return ctx.Err()
		},
	}

	firstResult := make(chan *OpenRungBrokerResult, 1)
	go func() {
		firstResult <- operation.SendTelemetryBatchJSON(
			"http://127.0.0.1:8080",
			validOpenRungTelemetryBatch("client-a", "session-a"),
		)
	}()
	<-started

	second := operation.DownloadSpeedTest("http://127.0.0.1:8080", 1)
	if second.Succeeded() || second.ErrorKind() != "validation" {
		t.Fatalf(
			"concurrent second invocation = success:%v kind:%q",
			second.Succeeded(),
			second.ErrorKind(),
		)
	}

	var closes sync.WaitGroup
	closes.Add(2)
	go func() {
		defer closes.Done()
		operation.Close()
	}()
	go func() {
		defer closes.Done()
		operation.Close()
	}()
	closesDone := make(chan struct{})
	go func() {
		closes.Wait()
		close(closesDone)
	}()
	select {
	case <-closesDone:
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not promptly cancel the in-flight broker request")
	}

	first := <-firstResult
	if first.Succeeded() || first.ErrorKind() != "cancelled" {
		t.Fatalf(
			"cancelled first invocation = success:%v kind:%q",
			first.Succeeded(),
			first.ErrorKind(),
		)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("network calls = %d, want 1", got)
	}
	repeated := operation.FirstReachable("", 5, "", "")
	if repeated.Succeeded() || repeated.ErrorKind() != "validation" {
		t.Fatalf(
			"repeated invocation = success:%v kind:%q",
			repeated.Succeeded(),
			repeated.ErrorKind(),
		)
	}
}

func TestOpenRungBrokerCloseBeforeInvocationReturnsCancelled(t *testing.T) {
	operation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
	operation.Close()
	operation.Close()
	result := operation.FetchManifestCandidate(
		"https://broker.openrung.org/api/v1/app-manifest",
	)
	if result.Succeeded() || result.ErrorKind() != "cancelled" {
		t.Fatalf("closed result = success:%v kind:%q", result.Succeeded(), result.ErrorKind())
	}
}

func TestOpenRungManifestFetchIsExactBoundedAndUsesConstructorHeaders(t *testing.T) {
	const body = " \n{\"version\":\"1.2.3\"}\n"
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.URL.Path != openRungManifestPath {
			t.Errorf("manifest request = %s %s", request.Method, request.URL.String())
		}
		for header, want := range map[string]string{
			"Accept":                 "application/json",
			"Cache-Control":          "no-cache, no-store",
			"Pragma":                 "no-cache",
			"X-OpenRung-App-Version": "1.2.3",
			"X-OpenRung-Android-API": "35",
			"X-OpenRung-iOS-Version": "",
			"X-OpenRung-RN":          "",
			"X-OpenRung-Client-ID":   "",
			"X-OpenRung-Session-ID":  "",
		} {
			if got := request.Header.Get(header); got != want {
				t.Errorf("%s = %q, want %q", header, got, want)
			}
		}
		_, _ = io.WriteString(response, body)
	}))
	defer server.Close()

	candidateURL := server.URL + openRungManifestPath
	operation := NewOpenRungBrokerOperationForAndroid(" 1.2.3 ", " 35 ")
	result := operation.FetchManifestCandidate(candidateURL)
	operation.Close()
	if !result.Succeeded() ||
		result.BodyJSON() != body ||
		result.SourceURL() != candidateURL {
		t.Fatalf(
			"manifest = success:%v body:%q source:%q kind:%q",
			result.Succeeded(),
			result.BodyJSON(),
			result.SourceURL(),
			result.ErrorKind(),
		)
	}
}

func TestOpenRungManifestHeadersMatchEveryConstructorPlatform(t *testing.T) {
	tests := []struct {
		name        string
		operation   OpenRungBrokerOperation
		wantHeader  string
		wantValue   string
		notExpected []string
	}{
		{
			name:       "android",
			operation:  NewOpenRungBrokerOperationForAndroid("1.2.3", "35"),
			wantHeader: "X-OpenRung-Android-API",
			wantValue:  "35",
			notExpected: []string{
				"X-OpenRung-iOS-Version",
				"X-OpenRung-RN",
			},
		},
		{
			name:       "ios",
			operation:  NewOpenRungBrokerOperationForIOS("1.2.3", "18.5"),
			wantHeader: "X-OpenRung-iOS-Version",
			wantValue:  "18.5",
			notExpected: []string{
				"X-OpenRung-Android-API",
				"X-OpenRung-RN",
			},
		},
		{
			name:       "react-native",
			operation:  NewOpenRungBrokerOperationForReactNative("1.2.3", "ios"),
			wantHeader: "X-OpenRung-RN",
			wantValue:  "ios",
			notExpected: []string{
				"X-OpenRung-Android-API",
				"X-OpenRung-iOS-Version",
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			defer test.operation.Close()
			implementation := openRungBrokerImplementation(t, test.operation)
			request := httptest.NewRequest(
				http.MethodGet,
				"https://broker.openrung.org"+openRungManifestPath,
				nil,
			)
			addOpenRungManifestHeaders(request, implementation.options)
			if got := request.Header.Get(test.wantHeader); got != test.wantValue {
				t.Fatalf("%s = %q, want %q", test.wantHeader, got, test.wantValue)
			}
			for _, name := range test.notExpected {
				if got := request.Header.Get(name); got != "" {
					t.Fatalf("unexpected %s = %q", name, got)
				}
			}
		})
	}
}

func TestOpenRungManifestRefusesRedirects(t *testing.T) {
	var redirected atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		redirected.Add(1)
		_, _ = io.WriteString(response, `{"unexpected":true}`)
	}))
	defer destination.Close()
	source := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(
			response,
			request,
			destination.URL+openRungManifestPath,
			http.StatusFound,
		)
	}))
	defer source.Close()

	operation := NewOpenRungBrokerOperationForReactNative("1.2.3", "ios")
	result := operation.FetchManifestCandidate(source.URL + openRungManifestPath)
	operation.Close()
	if result.Succeeded() ||
		result.ErrorKind() != "http_status" ||
		result.HTTPStatus() != http.StatusFound {
		t.Fatalf(
			"redirect result = success:%v kind:%q status:%d",
			result.Succeeded(),
			result.ErrorKind(),
			result.HTTPStatus(),
		)
	}
	if redirected.Load() != 0 {
		t.Fatal("manifest redirect was followed")
	}
}

func TestOpenRungManifestCandidatePolicy(t *testing.T) {
	accepted := []string{
		"https://broker.openrung.org/api/v1/app-manifest",
		"https://broker.openrung.org:443/api/v1/app-manifest",
		"https://d2r7mdpyevvs1m.cloudfront.net/api/v1/app-manifest",
		"http://localhost:8080/api/v1/app-manifest",
		"http://localhost:65535/api/v1/app-manifest",
		"https://127.0.0.1:8443/api/v1/app-manifest",
		"http://[::1]:8080/api/v1/app-manifest",
	}
	for _, candidate := range accepted {
		if got, err := validateOpenRungManifestCandidate(candidate); err != nil || got != candidate {
			t.Errorf("accepted candidate %q = %q, %v", candidate, got, err)
		}
	}

	rejected := []string{
		"",
		"https://github.com/openrung/openrung-mobile-app/releases/latest/download/update-manifest.json",
		"https://user:password@broker.openrung.org/api/v1/app-manifest",
		"https://broker.openrung.org/api/v1/app-manifest#fragment",
		"https://broker.openrung.org/api/v1/app-manifest?cache=off",
		"http://broker.openrung.org/api/v1/app-manifest",
		"ftp://broker.openrung.org/api/v1/app-manifest",
		"https://broker.openrung.org:444/api/v1/app-manifest",
		"http://localhost:/api/v1/app-manifest",
		"http://localhost:0/api/v1/app-manifest",
		"http://localhost:65536/api/v1/app-manifest",
		"https://broker.openrung.org/healthz",
		"https://broker.openrung.org/api/v1/%61pp-manifest",
		"https://broker.openrung.org.evil.example/api/v1/app-manifest",
	}
	for _, candidate := range rejected {
		if _, err := validateOpenRungManifestCandidate(candidate); err == nil {
			t.Errorf("candidate unexpectedly accepted: %q", candidate)
		}
	}
}

func TestOpenRungManifestRejectsOversizedAndInvalidUTF8Bodies(t *testing.T) {
	for name, body := range map[string][]byte{
		"oversized": bytes.Repeat([]byte("x"), openRungManifestMaxBodyBytes+1),
		"invalid UTF-8": {
			'{', '"', 'x', '"', ':', '"', 0xff, '"', '}',
		},
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
				_, _ = response.Write(body)
			}))
			defer server.Close()

			operation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
			result := operation.FetchManifestCandidate(server.URL + openRungManifestPath)
			operation.Close()
			if result.Succeeded() ||
				result.ErrorKind() != "validation" ||
				result.BodyJSON() != "" {
				t.Fatalf(
					"body result = success:%v kind:%q body length:%d",
					result.Succeeded(),
					result.ErrorKind(),
					len(result.BodyJSON()),
				)
			}
		})
	}
}

func TestOpenRungManifestStatusDoesNotExposeServerBody(t *testing.T) {
	const secret = "unbounded-server-secret"
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusServiceUnavailable)
		_, _ = io.WriteString(response, strings.Repeat(secret, 1024))
	}))
	defer server.Close()

	operation := NewOpenRungBrokerOperationForIOS("1.2.3", "18.5")
	result := operation.FetchManifestCandidate(server.URL + openRungManifestPath)
	operation.Close()
	if result.Succeeded() ||
		result.ErrorKind() != "http_status" ||
		result.HTTPStatus() != http.StatusServiceUnavailable {
		t.Fatalf(
			"status result = success:%v kind:%q status:%d",
			result.Succeeded(),
			result.ErrorKind(),
			result.HTTPStatus(),
		)
	}
	if strings.Contains(result.ErrorText(), secret) || len(result.ErrorText()) > 256 {
		t.Fatalf("unsafe ErrorText = %q", result.ErrorText())
	}
}

func TestOpenRungManifestRateLimitReturnsBoundedRetryHint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Retry-After", "7")
		response.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	operation := NewOpenRungBrokerOperationForReactNative("1.2.3", "ios")
	result := operation.FetchManifestCandidate(server.URL + openRungManifestPath)
	operation.Close()
	if result.Succeeded() ||
		result.ErrorKind() != "rate_limited" ||
		result.HTTPStatus() != http.StatusTooManyRequests ||
		result.RetryAfterMillis() != 7000 {
		t.Fatalf(
			"rate limit = success:%v kind:%q status:%d retry:%d",
			result.Succeeded(),
			result.ErrorKind(),
			result.HTTPStatus(),
			result.RetryAfterMillis(),
		)
	}
}

type openRungTimeoutError struct{}

func (openRungTimeoutError) Error() string   { return "secret timeout details" }
func (openRungTimeoutError) Timeout() bool   { return true }
func (openRungTimeoutError) Temporary() bool { return true }

func TestClassifyOpenRungBrokerErrors(t *testing.T) {
	tests := []struct {
		name       string
		ctx        context.Context
		err        error
		wantKind   string
		wantStatus int32
		wantRetry  int64
	}{
		{
			name:     "cancelled",
			ctx:      context.Background(),
			err:      fmt.Errorf("wrapped: %w", context.Canceled),
			wantKind: "cancelled",
		},
		{
			name:     "deadline",
			ctx:      context.Background(),
			err:      fmt.Errorf("wrapped: %w", context.DeadlineExceeded),
			wantKind: "timeout",
		},
		{
			name:     "net timeout",
			ctx:      context.Background(),
			err:      openRungTimeoutError{},
			wantKind: "timeout",
		},
		{
			name: "rate limited",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &brokerapi.RateLimitedError{
				RetryAfter: 4 * time.Second,
			}),
			wantKind:   "rate_limited",
			wantStatus: http.StatusTooManyRequests,
			wantRetry:  4000,
		},
		{
			name: "broker HTTP status",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &brokerapi.BrokerStatusError{
				StatusCode: http.StatusBadGateway,
				Message:    strings.Repeat("secret", 10_000),
			}),
			wantKind:   "http_status",
			wantStatus: http.StatusBadGateway,
		},
		{
			name: "broker HTTP 429",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &brokerapi.BrokerStatusError{
				StatusCode: http.StatusTooManyRequests,
			}),
			wantKind:   "rate_limited",
			wantStatus: http.StatusTooManyRequests,
		},
		{
			name: "WSS rate limited",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &brokerapi.WSSTicketStatusError{
				StatusCode: http.StatusTooManyRequests,
				RetryAfter: 2 * time.Second,
			}),
			wantKind:   "rate_limited",
			wantStatus: http.StatusTooManyRequests,
			wantRetry:  2000,
		},
		{
			name: "WSS HTTP status",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &brokerapi.WSSTicketStatusError{
				StatusCode: http.StatusForbidden,
			}),
			wantKind:   "http_status",
			wantStatus: http.StatusForbidden,
		},
		{
			name: "manifest HTTP status",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &openRungManifestStatusError{
				statusCode: http.StatusServiceUnavailable,
			}),
			wantKind:   "http_status",
			wantStatus: http.StatusServiceUnavailable,
		},
		{
			name:     "verification",
			ctx:      context.Background(),
			err:      fmt.Errorf("outer: %w", &brokerapi.RelayListVerificationError{Reason: "secret response"}),
			wantKind: "verification",
		},
		{
			name:     "DNS",
			ctx:      context.Background(),
			err:      fmt.Errorf("outer: %w", &net.DNSError{Name: "private.example", Err: "no such host"}),
			wantKind: "dns",
		},
		{
			name:     "TLS alert",
			ctx:      context.Background(),
			err:      fmt.Errorf("outer: %w", tls.AlertError(40)),
			wantKind: "tls",
		},
		{
			name:     "x509 critical extension",
			ctx:      context.Background(),
			err:      fmt.Errorf("outer: %w", x509.UnhandledCriticalExtension{}),
			wantKind: "tls",
		},
		{
			name: "network",
			ctx:  context.Background(),
			err: fmt.Errorf("outer: %w", &net.OpError{
				Op:  "dial",
				Net: "tcp",
				Err: errors.New("secret address"),
			}),
			wantKind: "network",
		},
		{
			name:     "validation",
			ctx:      context.Background(),
			err:      fmt.Errorf("outer: %w", openRungClassifiedError("validation")),
			wantKind: "validation",
		},
		{
			name:     "unknown",
			ctx:      context.Background(),
			err:      errors.New("secret arbitrary failure"),
			wantKind: "unknown",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			outcome := classifyOpenRungBrokerError(test.ctx, test.err)
			if outcome.succeeded ||
				outcome.errorKind != test.wantKind ||
				outcome.httpStatus != test.wantStatus ||
				outcome.retryAfterMillis != test.wantRetry {
				t.Fatalf("outcome = %+v", outcome)
			}
			if strings.Contains(strings.ToLower(outcome.errorText), "secret") ||
				len(outcome.errorText) > 256 {
				t.Fatalf("unsafe ErrorText = %q", outcome.errorText)
			}
		})
	}
}
