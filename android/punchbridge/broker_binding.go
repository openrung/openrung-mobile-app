// Package libbox exposes OpenRung's broker transport through the same gomobile
// package and Go runtime as sing-box.
package libbox

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/openrung/openrung/brokerapi"
)

const (
	openRungManifestPath         = "/api/v1/app-manifest"
	openRungManifestMaxBodyBytes = 1 << 20
	openRungManifestTimeout      = 10 * time.Second
)

var errOpenRungBrokerOperationUsed = errors.New("OpenRung broker operation may be invoked only once")

// OpenRungBrokerOperation is one cancelable broker request. It is an interface
// so gomobile keeps the three same-signature New functions as distinct package
// functions instead of collapsing them into duplicate Java constructors.
//
// Every operation is single-use: exactly one of the network methods may be
// called. Close may run concurrently with that method and is idempotent.
type OpenRungBrokerOperation interface {
	FirstReachable(primary string, limit int32, clientID, sessionID string) *OpenRungBrokerRelayResult
	SendTelemetryBatchJSON(brokerURL, batchJSON string) *OpenRungBrokerResult
	RequestWSSTicket(
		brokerURL, relayID, frontID, clientID, sessionID string,
	) *OpenRungBrokerWSSTicketResult
	RunSpeedTest(brokerURL string) *OpenRungBrokerSpeedTestResult
	DownloadSpeedTest(brokerURL string, byteCount int32) *OpenRungBrokerSpeedTestResult
	FetchManifestCandidate(candidateURL string) *OpenRungBrokerManifestResult
	Close()
}

// OpenRungBrokerResult is the common result for a broker operation that has no
// operation-specific success values.
type OpenRungBrokerResult struct {
	outcome openRungBrokerOutcome
}

func (r *OpenRungBrokerResult) Succeeded() bool {
	return r != nil && r.outcome.succeeded
}

func (r *OpenRungBrokerResult) ErrorKind() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorKind
}

func (r *OpenRungBrokerResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorText
}

func (r *OpenRungBrokerResult) HTTPStatus() int32 {
	if r == nil {
		return 0
	}
	return r.outcome.httpStatus
}

func (r *OpenRungBrokerResult) RetryAfterMillis() int64 {
	if r == nil {
		return 0
	}
	return r.outcome.retryAfterMillis
}

// OpenRungBrokerRelayResult contains one verified relay list and the broker
// front that served it.
type OpenRungBrokerRelayResult struct {
	outcome           openRungBrokerOutcome
	brokerURL         string
	relayJSON         string
	keyID             string
	signatureVerified bool
}

func (r *OpenRungBrokerRelayResult) Succeeded() bool {
	return r != nil && r.outcome.succeeded
}

func (r *OpenRungBrokerRelayResult) ErrorKind() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorKind
}

func (r *OpenRungBrokerRelayResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorText
}

func (r *OpenRungBrokerRelayResult) HTTPStatus() int32 {
	if r == nil {
		return 0
	}
	return r.outcome.httpStatus
}

func (r *OpenRungBrokerRelayResult) RetryAfterMillis() int64 {
	if r == nil {
		return 0
	}
	return r.outcome.retryAfterMillis
}

func (r *OpenRungBrokerRelayResult) BrokerURL() string {
	if r == nil {
		return ""
	}
	return r.brokerURL
}

func (r *OpenRungBrokerRelayResult) RelayJSON() string {
	if r == nil {
		return ""
	}
	return r.relayJSON
}

func (r *OpenRungBrokerRelayResult) KeyID() string {
	if r == nil {
		return ""
	}
	return r.keyID
}

func (r *OpenRungBrokerRelayResult) SignatureVerified() bool {
	return r != nil && r.signatureVerified
}

// OpenRungBrokerWSSTicketResult contains one validated, short-lived WSS
// credential. String and GoString deliberately redact both credential fields.
type OpenRungBrokerWSSTicketResult struct {
	outcome         openRungBrokerOutcome
	ticket          string
	url             string
	expiresAtMillis int64
}

func (r *OpenRungBrokerWSSTicketResult) Succeeded() bool {
	return r != nil && r.outcome.succeeded
}

func (r *OpenRungBrokerWSSTicketResult) ErrorKind() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorKind
}

func (r *OpenRungBrokerWSSTicketResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorText
}

func (r *OpenRungBrokerWSSTicketResult) HTTPStatus() int32 {
	if r == nil {
		return 0
	}
	return r.outcome.httpStatus
}

func (r *OpenRungBrokerWSSTicketResult) RetryAfterMillis() int64 {
	if r == nil {
		return 0
	}
	return r.outcome.retryAfterMillis
}

func (r *OpenRungBrokerWSSTicketResult) Ticket() string {
	if r == nil {
		return ""
	}
	return r.ticket
}

func (r *OpenRungBrokerWSSTicketResult) URL() string {
	if r == nil {
		return ""
	}
	return r.url
}

func (r *OpenRungBrokerWSSTicketResult) ExpiresAtMillis() int64 {
	if r == nil {
		return 0
	}
	return r.expiresAtMillis
}

func (r OpenRungBrokerWSSTicketResult) String() string {
	return fmt.Sprintf(
		"OpenRungBrokerWSSTicketResult{Succeeded:%t, ErrorKind:%q, HTTPStatus:%d, "+
			"RetryAfterMillis:%d, Ticket:<redacted>, URL:<redacted>, ExpiresAtMillis:%d}",
		r.Succeeded(),
		r.ErrorKind(),
		r.HTTPStatus(),
		r.RetryAfterMillis(),
		r.ExpiresAtMillis(),
	)
}

func (r OpenRungBrokerWSSTicketResult) GoString() string {
	return r.String()
}

// OpenRungBrokerSpeedTestResult contains brokerapi's complete-request speed
// measurement. Mbps intentionally uses TotalDuration, not download-only time.
type OpenRungBrokerSpeedTestResult struct {
	outcome                openRungBrokerOutcome
	bytes                  int64
	ttfbMillis             int64
	downloadDurationMillis int64
	totalDurationMillis    int64
	mbps                   float64
}

func (r *OpenRungBrokerSpeedTestResult) Succeeded() bool {
	return r != nil && r.outcome.succeeded
}

func (r *OpenRungBrokerSpeedTestResult) ErrorKind() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorKind
}

func (r *OpenRungBrokerSpeedTestResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorText
}

func (r *OpenRungBrokerSpeedTestResult) HTTPStatus() int32 {
	if r == nil {
		return 0
	}
	return r.outcome.httpStatus
}

func (r *OpenRungBrokerSpeedTestResult) RetryAfterMillis() int64 {
	if r == nil {
		return 0
	}
	return r.outcome.retryAfterMillis
}

func (r *OpenRungBrokerSpeedTestResult) Bytes() int64 {
	if r == nil {
		return 0
	}
	return r.bytes
}

func (r *OpenRungBrokerSpeedTestResult) TTFBMillis() int64 {
	if r == nil {
		return 0
	}
	return r.ttfbMillis
}

func (r *OpenRungBrokerSpeedTestResult) DownloadDurationMillis() int64 {
	if r == nil {
		return 0
	}
	return r.downloadDurationMillis
}

func (r *OpenRungBrokerSpeedTestResult) TotalDurationMillis() int64 {
	if r == nil {
		return 0
	}
	return r.totalDurationMillis
}

func (r *OpenRungBrokerSpeedTestResult) Mbps() float64 {
	if r == nil {
		return 0
	}
	return r.mbps
}

// OpenRungBrokerManifestResult contains one transport-only manifest candidate.
// Signature, rollback, freshness, and fail-open policy remain platform-owned.
type OpenRungBrokerManifestResult struct {
	outcome   openRungBrokerOutcome
	bodyJSON  string
	sourceURL string
}

func (r *OpenRungBrokerManifestResult) Succeeded() bool {
	return r != nil && r.outcome.succeeded
}

func (r *OpenRungBrokerManifestResult) ErrorKind() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorKind
}

func (r *OpenRungBrokerManifestResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorText
}

func (r *OpenRungBrokerManifestResult) HTTPStatus() int32 {
	if r == nil {
		return 0
	}
	return r.outcome.httpStatus
}

func (r *OpenRungBrokerManifestResult) RetryAfterMillis() int64 {
	if r == nil {
		return 0
	}
	return r.outcome.retryAfterMillis
}

func (r *OpenRungBrokerManifestResult) BodyJSON() string {
	if r == nil {
		return ""
	}
	return r.bodyJSON
}

func (r *OpenRungBrokerManifestResult) SourceURL() string {
	if r == nil {
		return ""
	}
	return r.sourceURL
}

type openRungBrokerOutcome struct {
	succeeded        bool
	errorKind        string
	errorText        string
	httpStatus       int32
	retryAfterMillis int64
}

type openRungBrokerClient interface {
	FirstReachable(
		context.Context,
		brokerapi.Candidates,
		brokerapi.ListOptions,
	) (brokerapi.Fetch, error)
	SendTelemetryBatchJSON(context.Context, string, []byte) error
	RequestWSSTicket(
		context.Context,
		string,
		brokerapi.WSSTicketRequest,
	) (brokerapi.WSSTicketResponse, error)
	RunSpeedTest(context.Context, string) (brokerapi.SpeedTestResult, error)
	DownloadSpeedTest(context.Context, string, int) (brokerapi.SpeedTestResult, error)
}

type openRungBrokerOperation struct {
	mu sync.Mutex

	ctx    context.Context
	cancel context.CancelFunc

	client         openRungBrokerClient
	manifestClient *http.Client
	options        brokerapi.Options

	attemptDone chan struct{}
	closeDone   chan struct{}
	attempted   bool
	closed      bool
}

// NewOpenRungBrokerOperationForAndroid selects brokerapi's Android header and
// ECH-capable default transport.
func NewOpenRungBrokerOperationForAndroid(appVersion, apiLevel string) OpenRungBrokerOperation {
	return newOpenRungBrokerOperation(brokerapi.Options{
		AppVersion:      appVersion,
		Platform:        brokerapi.PlatformAndroid,
		PlatformVersion: apiLevel,
	})
}

// NewOpenRungBrokerOperationForIOS selects brokerapi's iOS header and
// ECH-capable default transport.
func NewOpenRungBrokerOperationForIOS(appVersion, osVersion string) OpenRungBrokerOperation {
	return newOpenRungBrokerOperation(brokerapi.Options{
		AppVersion:      appVersion,
		Platform:        brokerapi.PlatformIOS,
		PlatformVersion: osVersion,
	})
}

// NewOpenRungBrokerOperationForReactNative selects brokerapi's React Native
// header. Platform is a single string enum; Android and iOS are never combined.
func NewOpenRungBrokerOperationForReactNative(appVersion, osToken string) OpenRungBrokerOperation {
	return newOpenRungBrokerOperation(brokerapi.Options{
		AppVersion:      appVersion,
		Platform:        brokerapi.PlatformReactNative,
		PlatformVersion: osToken,
	})
}

func newOpenRungBrokerOperation(options brokerapi.Options) OpenRungBrokerOperation {
	ctx, cancel := context.WithCancel(context.Background())
	return &openRungBrokerOperation{
		ctx:    ctx,
		cancel: cancel,
		// Passing nil is required: brokerapi selects its shared, opportunistic-
		// ECH transport and verified ordinary-TLS fallback.
		client:         brokerapi.NewClient(nil, options),
		manifestClient: brokerapi.NewHTTPClient(openRungManifestTimeout),
		options:        options,
		closeDone:      make(chan struct{}),
	}
}

func (o *openRungBrokerOperation) begin() (context.Context, chan struct{}, error) {
	if o == nil {
		return nil, nil, openRungClassifiedError("validation")
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.attempted {
		return nil, nil, errOpenRungBrokerOperationUsed
	}
	if o.closed {
		return nil, nil, context.Canceled
	}
	o.attempted = true
	o.attemptDone = make(chan struct{})
	return o.ctx, o.attemptDone, nil
}

func (o *openRungBrokerOperation) FirstReachable(
	primary string,
	limit int32,
	clientID string,
	sessionID string,
) *OpenRungBrokerRelayResult {
	ctx, done, err := o.begin()
	if err != nil {
		return failedOpenRungBrokerRelayResult(ctx, err)
	}
	defer close(done)
	if o.client == nil {
		return failedOpenRungBrokerRelayResult(ctx, openRungClassifiedError("validation"))
	}

	candidates := brokerapi.BrokerCandidates(primary)
	invalidOverride := false
	if candidates.OverrideFirst && len(candidates.URLs) > 0 {
		_, candidateErr := brokerapi.RelayListURL(candidates.URLs[0], int(limit))
		invalidOverride = candidateErr != nil
	}
	fetch, err := o.client.FirstReachable(ctx, candidates, brokerapi.ListOptions{
		Limit: int(limit),
		Identity: brokerapi.Identity{
			ClientID:  clientID,
			SessionID: sessionID,
		},
	})
	if err != nil {
		if invalidOverride && ctx.Err() == nil {
			err = openRungClassifiedError("validation")
		}
		return failedOpenRungBrokerRelayResult(ctx, err)
	}
	if ctx.Err() != nil {
		return failedOpenRungBrokerRelayResult(ctx, ctx.Err())
	}
	relayJSON := fetch.RelayList.JSON()
	if !utf8.Valid(relayJSON) {
		return failedOpenRungBrokerRelayResult(
			ctx,
			openRungClassifiedError("verification"),
		)
	}
	return &OpenRungBrokerRelayResult{
		outcome:           successfulOpenRungBrokerOutcome(),
		brokerURL:         fetch.BrokerURL,
		relayJSON:         string(relayJSON),
		keyID:             fetch.RelayList.KeyID,
		signatureVerified: fetch.RelayList.SignatureVerified,
	}
}

func (o *openRungBrokerOperation) SendTelemetryBatchJSON(
	brokerURL string,
	batchJSON string,
) *OpenRungBrokerResult {
	ctx, done, err := o.begin()
	if err != nil {
		return failedOpenRungBrokerResult(ctx, err)
	}
	defer close(done)
	if o.client == nil {
		return failedOpenRungBrokerResult(ctx, openRungClassifiedError("validation"))
	}
	hasEvents, err := validateOpenRungTelemetryBatchJSON(batchJSON)
	if err != nil {
		return failedOpenRungBrokerResult(ctx, err)
	}
	if hasEvents {
		if _, err := brokerapi.TelemetryURL(brokerURL); err != nil {
			return failedOpenRungBrokerResult(ctx, openRungClassifiedError("validation"))
		}
	}
	if err := o.client.SendTelemetryBatchJSON(ctx, brokerURL, []byte(batchJSON)); err != nil {
		return failedOpenRungBrokerResult(ctx, err)
	}
	if ctx.Err() != nil {
		return failedOpenRungBrokerResult(ctx, ctx.Err())
	}
	return &OpenRungBrokerResult{outcome: successfulOpenRungBrokerOutcome()}
}

func (o *openRungBrokerOperation) RequestWSSTicket(
	brokerURL string,
	relayID string,
	frontID string,
	clientID string,
	sessionID string,
) *OpenRungBrokerWSSTicketResult {
	ctx, done, err := o.begin()
	if err != nil {
		return failedOpenRungBrokerWSSTicketResult(ctx, err)
	}
	defer close(done)
	if o.client == nil {
		return failedOpenRungBrokerWSSTicketResult(ctx, openRungClassifiedError("validation"))
	}
	if strings.TrimSpace(relayID) == "" || strings.TrimSpace(frontID) == "" {
		return failedOpenRungBrokerWSSTicketResult(ctx, openRungClassifiedError("validation"))
	}
	if _, err := brokerapi.WSSTicketURL(brokerURL); err != nil {
		return failedOpenRungBrokerWSSTicketResult(ctx, openRungClassifiedError("validation"))
	}
	ticket, err := o.client.RequestWSSTicket(ctx, brokerURL, brokerapi.WSSTicketRequest{
		RelayID: relayID,
		FrontID: frontID,
		Identity: brokerapi.Identity{
			ClientID:  clientID,
			SessionID: sessionID,
		},
	})
	if err != nil {
		return failedOpenRungBrokerWSSTicketResult(ctx, err)
	}
	if ctx.Err() != nil {
		return failedOpenRungBrokerWSSTicketResult(ctx, ctx.Err())
	}
	return &OpenRungBrokerWSSTicketResult{
		outcome:         successfulOpenRungBrokerOutcome(),
		ticket:          ticket.Ticket,
		url:             ticket.URL,
		expiresAtMillis: ticket.ExpiresAt.UnixMilli(),
	}
}

func (o *openRungBrokerOperation) RunSpeedTest(
	brokerURL string,
) *OpenRungBrokerSpeedTestResult {
	ctx, done, err := o.begin()
	if err != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, err)
	}
	defer close(done)
	if o.client == nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, openRungClassifiedError("validation"))
	}
	if _, err := brokerapi.SpeedTestURL(
		brokerURL,
		brokerapi.DefaultSpeedTestWarmupBytes,
	); err != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, openRungClassifiedError("validation"))
	}
	result, err := o.client.RunSpeedTest(ctx, brokerURL)
	if err != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, err)
	}
	if ctx.Err() != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, ctx.Err())
	}
	return successfulOpenRungBrokerSpeedTestResult(result)
}

func (o *openRungBrokerOperation) DownloadSpeedTest(
	brokerURL string,
	byteCount int32,
) *OpenRungBrokerSpeedTestResult {
	ctx, done, err := o.begin()
	if err != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, err)
	}
	defer close(done)
	if o.client == nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, openRungClassifiedError("validation"))
	}
	if _, err := brokerapi.SpeedTestURL(brokerURL, int(byteCount)); err != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, openRungClassifiedError("validation"))
	}
	result, err := o.client.DownloadSpeedTest(ctx, brokerURL, int(byteCount))
	if err != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, err)
	}
	if ctx.Err() != nil {
		return failedOpenRungBrokerSpeedTestResult(ctx, ctx.Err())
	}
	return successfulOpenRungBrokerSpeedTestResult(result)
}

func (o *openRungBrokerOperation) FetchManifestCandidate(
	candidateURL string,
) *OpenRungBrokerManifestResult {
	ctx, done, err := o.begin()
	if err != nil {
		return failedOpenRungBrokerManifestResult(ctx, err)
	}
	defer close(done)
	if o.manifestClient == nil {
		return failedOpenRungBrokerManifestResult(ctx, openRungClassifiedError("validation"))
	}
	sourceURL, err := validateOpenRungManifestCandidate(candidateURL)
	if err != nil {
		return failedOpenRungBrokerManifestResult(ctx, err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return failedOpenRungBrokerManifestResult(ctx, openRungClassifiedError("validation"))
	}
	addOpenRungManifestHeaders(request, o.options)

	response, err := o.manifestClient.Do(request)
	if err != nil {
		return failedOpenRungBrokerManifestResult(ctx, err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return failedOpenRungBrokerManifestResult(ctx, &openRungManifestStatusError{
			statusCode: response.StatusCode,
			retryAfter: parseOpenRungRetryAfter(response.Header.Get("Retry-After"), time.Now()),
		})
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, openRungManifestMaxBodyBytes+1))
	if err != nil {
		return failedOpenRungBrokerManifestResult(ctx, err)
	}
	if len(body) > openRungManifestMaxBodyBytes || !utf8.Valid(body) {
		return failedOpenRungBrokerManifestResult(ctx, openRungClassifiedError("validation"))
	}
	if ctx.Err() != nil {
		return failedOpenRungBrokerManifestResult(ctx, ctx.Err())
	}
	return &OpenRungBrokerManifestResult{
		outcome:   successfulOpenRungBrokerOutcome(),
		bodyJSON:  string(body),
		sourceURL: sourceURL,
	}
}

// Close cancels and waits for an in-flight request. It deliberately does not
// close brokerapi's shared global connection pool.
func (o *openRungBrokerOperation) Close() {
	if o == nil {
		return
	}
	o.mu.Lock()
	if o.closeDone == nil {
		o.closeDone = make(chan struct{})
	}
	if o.closed {
		closeDone := o.closeDone
		o.mu.Unlock()
		<-closeDone
		return
	}
	o.closed = true
	if o.cancel != nil {
		o.cancel()
	}
	attemptDone := o.attemptDone
	closeDone := o.closeDone
	o.mu.Unlock()

	if attemptDone != nil {
		<-attemptDone
	}
	close(closeDone)
}

// OpenRungDefaultBrokerURLsJSON returns brokerapi's fresh default order without
// exposing a Go slice through gomobile.
func OpenRungDefaultBrokerURLsJSON() string {
	encoded, err := json.Marshal(brokerapi.DefaultBrokerURLs())
	if err != nil {
		return "[]"
	}
	return string(encoded)
}

func validateOpenRungTelemetryBatchJSON(batchJSON string) (bool, error) {
	if !utf8.ValidString(batchJSON) || len(batchJSON) > brokerapi.MaxTelemetryBodyBytes {
		return false, openRungClassifiedError("validation")
	}
	var batch struct {
		Events []brokerapi.TelemetryEvent `json:"events"`
	}
	decoder := json.NewDecoder(strings.NewReader(batchJSON))
	if err := decoder.Decode(&batch); err != nil {
		return false, openRungClassifiedError("validation")
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return false, openRungClassifiedError("validation")
	}
	if len(batch.Events) > brokerapi.MaxTelemetryEvents {
		return false, openRungClassifiedError("validation")
	}
	if len(batch.Events) == 0 {
		return false, nil
	}
	clientID := batch.Events[0].ClientID
	sessionID := batch.Events[0].SessionID
	for _, event := range batch.Events[1:] {
		if event.ClientID != clientID || event.SessionID != sessionID {
			return false, openRungClassifiedError("validation")
		}
	}
	return true, nil
}

func validateOpenRungManifestCandidate(candidateURL string) (string, error) {
	candidateURL = strings.TrimSpace(candidateURL)
	if candidateURL == "" || strings.Contains(candidateURL, "#") {
		return "", openRungClassifiedError("validation")
	}
	parsed, err := url.Parse(candidateURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.Opaque != "" {
		return "", openRungClassifiedError("validation")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" {
		return "", openRungClassifiedError("validation")
	}
	if parsed.Path != openRungManifestPath || parsed.EscapedPath() != openRungManifestPath {
		return "", openRungClassifiedError("validation")
	}

	scheme := strings.ToLower(parsed.Scheme)
	host := parsed.Hostname()
	port := parsed.Port()
	if strings.HasSuffix(parsed.Host, ":") {
		return "", openRungClassifiedError("validation")
	}
	if openRungHostIsLoopback(host) {
		if scheme != "http" && scheme != "https" {
			return "", openRungClassifiedError("validation")
		}
		if port != "" {
			portNumber, err := strconv.Atoi(port)
			if err != nil || portNumber < 1 || portNumber > 65535 {
				return "", openRungClassifiedError("validation")
			}
		}
	} else {
		if scheme != "https" ||
			(!strings.EqualFold(host, "broker.openrung.org") &&
				!strings.EqualFold(host, "d2r7mdpyevvs1m.cloudfront.net")) ||
			(port != "" && port != "443") {
			return "", openRungClassifiedError("validation")
		}
	}
	return parsed.String(), nil
}

func openRungHostIsLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

func addOpenRungManifestHeaders(request *http.Request, options brokerapi.Options) {
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Cache-Control", "no-cache, no-store")
	request.Header.Set("Pragma", "no-cache")
	if value := strings.TrimSpace(options.AppVersion); value != "" {
		request.Header.Set("X-OpenRung-App-Version", value)
	}
	switch options.Platform {
	case brokerapi.PlatformAndroid:
		if value := strings.TrimSpace(options.PlatformVersion); value != "" {
			request.Header.Set("X-OpenRung-Android-API", value)
		}
	case brokerapi.PlatformIOS:
		if value := strings.TrimSpace(options.PlatformVersion); value != "" {
			request.Header.Set("X-OpenRung-iOS-Version", value)
		}
	case brokerapi.PlatformReactNative:
		request.Header.Set(
			"X-OpenRung-RN",
			openRungPlatformHeaderValue(options.PlatformVersion),
		)
	}
}

func openRungPlatformHeaderValue(configured string) string {
	if configured = strings.TrimSpace(configured); configured != "" {
		return configured
	}
	if runtime.GOOS == "darwin" {
		return "ios"
	}
	return runtime.GOOS
}

type openRungClassifiedFailure struct {
	kind string
}

func (e *openRungClassifiedFailure) Error() string {
	return "OpenRung broker " + e.kind + " failure"
}

func openRungClassifiedError(kind string) error {
	return &openRungClassifiedFailure{kind: kind}
}

type openRungManifestStatusError struct {
	statusCode int
	retryAfter time.Duration
}

func (e *openRungManifestStatusError) Error() string {
	return fmt.Sprintf("manifest request failed with HTTP status %d", e.statusCode)
}

func successfulOpenRungBrokerOutcome() openRungBrokerOutcome {
	return openRungBrokerOutcome{succeeded: true}
}

func failedOpenRungBrokerResult(ctx context.Context, err error) *OpenRungBrokerResult {
	return &OpenRungBrokerResult{outcome: classifyOpenRungBrokerError(ctx, err)}
}

func failedOpenRungBrokerRelayResult(
	ctx context.Context,
	err error,
) *OpenRungBrokerRelayResult {
	return &OpenRungBrokerRelayResult{outcome: classifyOpenRungBrokerError(ctx, err)}
}

func failedOpenRungBrokerWSSTicketResult(
	ctx context.Context,
	err error,
) *OpenRungBrokerWSSTicketResult {
	return &OpenRungBrokerWSSTicketResult{outcome: classifyOpenRungBrokerError(ctx, err)}
}

func failedOpenRungBrokerSpeedTestResult(
	ctx context.Context,
	err error,
) *OpenRungBrokerSpeedTestResult {
	return &OpenRungBrokerSpeedTestResult{outcome: classifyOpenRungBrokerError(ctx, err)}
}

func failedOpenRungBrokerManifestResult(
	ctx context.Context,
	err error,
) *OpenRungBrokerManifestResult {
	return &OpenRungBrokerManifestResult{outcome: classifyOpenRungBrokerError(ctx, err)}
}

func successfulOpenRungBrokerSpeedTestResult(
	result brokerapi.SpeedTestResult,
) *OpenRungBrokerSpeedTestResult {
	return &OpenRungBrokerSpeedTestResult{
		outcome:                successfulOpenRungBrokerOutcome(),
		bytes:                  result.Bytes,
		ttfbMillis:             result.TTFB.Milliseconds(),
		downloadDurationMillis: result.DownloadDuration.Milliseconds(),
		totalDurationMillis:    result.TotalDuration.Milliseconds(),
		mbps:                   result.MegabitsPerSecond,
	}
}

func classifyOpenRungBrokerError(
	ctx context.Context,
	err error,
) openRungBrokerOutcome {
	if err == nil {
		return successfulOpenRungBrokerOutcome()
	}
	if (ctx != nil && errors.Is(ctx.Err(), context.Canceled)) ||
		errors.Is(err, context.Canceled) {
		return failedOpenRungBrokerOutcome("cancelled", 0, 0)
	}
	if (ctx != nil && errors.Is(ctx.Err(), context.DeadlineExceeded)) ||
		errors.Is(err, context.DeadlineExceeded) {
		return failedOpenRungBrokerOutcome("timeout", 0, 0)
	}
	var timeoutError interface{ Timeout() bool }
	if errors.As(err, &timeoutError) && timeoutError.Timeout() {
		return failedOpenRungBrokerOutcome("timeout", 0, 0)
	}

	var rateLimited *brokerapi.RateLimitedError
	if errors.As(err, &rateLimited) {
		return failedOpenRungBrokerOutcome(
			"rate_limited",
			http.StatusTooManyRequests,
			openRungDurationMillis(rateLimited.RetryAfter),
		)
	}
	var ticketStatus *brokerapi.WSSTicketStatusError
	if errors.As(err, &ticketStatus) {
		kind := "http_status"
		if ticketStatus.StatusCode == http.StatusTooManyRequests {
			kind = "rate_limited"
		}
		return failedOpenRungBrokerOutcome(
			kind,
			ticketStatus.StatusCode,
			openRungDurationMillis(ticketStatus.RetryAfter),
		)
	}
	var brokerStatus *brokerapi.BrokerStatusError
	if errors.As(err, &brokerStatus) {
		kind := "http_status"
		if brokerStatus.StatusCode == http.StatusTooManyRequests {
			kind = "rate_limited"
		}
		return failedOpenRungBrokerOutcome(kind, brokerStatus.StatusCode, 0)
	}
	var manifestStatus *openRungManifestStatusError
	if errors.As(err, &manifestStatus) {
		kind := "http_status"
		if manifestStatus.statusCode == http.StatusTooManyRequests {
			kind = "rate_limited"
		}
		return failedOpenRungBrokerOutcome(
			kind,
			manifestStatus.statusCode,
			openRungDurationMillis(manifestStatus.retryAfter),
		)
	}

	var verification *brokerapi.RelayListVerificationError
	if errors.As(err, &verification) {
		return failedOpenRungBrokerOutcome("verification", 0, 0)
	}
	var classified *openRungClassifiedFailure
	if errors.As(err, &classified) {
		return failedOpenRungBrokerOutcome(classified.kind, 0, 0)
	}
	if errors.Is(err, errOpenRungBrokerOperationUsed) {
		return failedOpenRungBrokerOutcome("validation", 0, 0)
	}

	var dnsError *net.DNSError
	if errors.As(err, &dnsError) {
		return failedOpenRungBrokerOutcome("dns", 0, 0)
	}
	if openRungIsTLSError(err) {
		return failedOpenRungBrokerOutcome("tls", 0, 0)
	}
	var networkError net.Error
	if errors.As(err, &networkError) {
		return failedOpenRungBrokerOutcome("network", 0, 0)
	}
	var operationError *net.OpError
	if errors.As(err, &operationError) {
		return failedOpenRungBrokerOutcome("network", 0, 0)
	}
	var urlError *url.Error
	if errors.As(err, &urlError) {
		return failedOpenRungBrokerOutcome("network", 0, 0)
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return failedOpenRungBrokerOutcome("network", 0, 0)
	}
	return failedOpenRungBrokerOutcome("unknown", 0, 0)
}

func openRungIsTLSError(err error) bool {
	var alert tls.AlertError
	if errors.As(err, &alert) {
		return true
	}
	var echRejection *tls.ECHRejectionError
	if errors.As(err, &echRejection) {
		return true
	}
	var certificateVerification *tls.CertificateVerificationError
	if errors.As(err, &certificateVerification) {
		return true
	}
	var recordHeader tls.RecordHeaderError
	if errors.As(err, &recordHeader) {
		return true
	}
	var unknownAuthority x509.UnknownAuthorityError
	if errors.As(err, &unknownAuthority) {
		return true
	}
	var hostname x509.HostnameError
	if errors.As(err, &hostname) {
		return true
	}
	var invalidCertificate x509.CertificateInvalidError
	if errors.As(err, &invalidCertificate) {
		return true
	}
	var systemRoots x509.SystemRootsError
	if errors.As(err, &systemRoots) {
		return true
	}
	var constraintViolation x509.ConstraintViolationError
	if errors.As(err, &constraintViolation) {
		return true
	}
	var unhandledCriticalExtension x509.UnhandledCriticalExtension
	if errors.As(err, &unhandledCriticalExtension) {
		return true
	}
	var insecureAlgorithm x509.InsecureAlgorithmError
	return errors.As(err, &insecureAlgorithm)
}

func failedOpenRungBrokerOutcome(
	kind string,
	httpStatus int,
	retryAfterMillis int64,
) openRungBrokerOutcome {
	status := int32(0)
	if httpStatus > 0 {
		status = int32(httpStatus)
	}
	return openRungBrokerOutcome{
		errorKind:        kind,
		errorText:        openRungBrokerErrorText(kind, status),
		httpStatus:       status,
		retryAfterMillis: retryAfterMillis,
	}
}

func openRungBrokerErrorText(kind string, status int32) string {
	switch kind {
	case "cancelled":
		return "Broker operation cancelled"
	case "timeout":
		return "Broker operation timed out"
	case "rate_limited":
		return "Broker request was rate-limited"
	case "http_status":
		if status > 0 {
			return fmt.Sprintf("Broker request failed with HTTP status %d", status)
		}
		return "Broker request failed with an HTTP error"
	case "dns":
		return "Broker DNS lookup failed"
	case "tls":
		return "Broker TLS connection failed"
	case "network":
		return "Broker network request failed"
	case "verification":
		return "Broker response verification failed"
	case "validation":
		return "Broker request validation failed"
	default:
		return "Broker request failed"
	}
}

func openRungDurationMillis(duration time.Duration) int64 {
	if duration <= 0 {
		return 0
	}
	return duration.Milliseconds()
}

func parseOpenRungRetryAfter(value string, now time.Time) time.Duration {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if seconds, err := strconv.ParseInt(value, 10, 64); err == nil {
		if seconds < 0 || seconds > int64((24*time.Hour)/time.Second) {
			return 0
		}
		return time.Duration(seconds) * time.Second
	}
	when, err := http.ParseTime(value)
	if err != nil || !when.After(now) {
		return 0
	}
	delay := when.Sub(now)
	if delay > 24*time.Hour {
		return 0
	}
	return delay
}
