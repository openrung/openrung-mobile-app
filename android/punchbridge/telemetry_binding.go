package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"sync"

	"github.com/openrung/openrung/brokerapi"
	"github.com/openrung/openrung/connectcore/clienttelemetry"
)

// OpenRungTelemetryOutbox is the shared on-disk telemetry outbox behind both
// platforms' TelemetryManager: an append-only NDJSON file (one
// brokerapi.TelemetryEvent per line) in a platform-supplied directory, plus
// the upload policy over it. It replaces the two divergent platform copies —
// the 0.3.5-upgrade regression surface — with one implementation: enqueue cap
// with oldest-first eviction, torn/undecodable lines skipped at load, the
// pre-NDJSON single-JSON-array file folded in on first touch, identity-
// homogeneous upload batches with the broker's per-application flow budget,
// and heartbeat piggybacking that can never let backlog delay the heartbeat.
// Posting goes through the same brokerapi client the broker binding uses.
//
// It is an interface for the same reason OpenRungBrokerOperation is: gomobile
// keeps the two same-signature New functions as distinct package functions
// instead of collapsing them into duplicate Java constructors.
//
// All methods are safe for concurrent use. Network sends hold no lock, so
// enqueues proceed during an upload; sent events are removed only after their
// request succeeded, atomically with the send outcome.
type OpenRungTelemetryOutbox interface {
	Enqueue(eventJSON string) bool
	EnqueueBatchJSON(eventsJSON string) int32
	ApplySessionAttributes(sessionID, attributesJSON string) bool
	PendingCount() int32
	BeginUpload() *OpenRungTelemetryUpload
	Close()
}

// Queue policy, persistence, migration, and locking live in connectcore.
// This adapter owns JSON conversion, broker error projection, and gomobile
// cancellation handles only (ADR-003 A3's paired mobile cleanup).
type openRungTelemetryOutbox struct {
	ctx    context.Context
	cancel context.CancelFunc
	queue  *clienttelemetry.Outbox
	poster openRungTelemetryPoster
}
type openRungTelemetryPoster interface {
	SendTelemetryBatchJSON(context.Context, string, []byte) error
}

// NewOpenRungTelemetryOutboxForAndroid opens (or creates) the outbox file
// fileName inside directory with brokerapi's Android posting header.
func NewOpenRungTelemetryOutboxForAndroid(
	directory, fileName, appVersion, apiLevel string,
) OpenRungTelemetryOutbox {
	return newOpenRungTelemetryOutbox(directory, fileName, brokerapi.Options{
		AppVersion:      appVersion,
		Platform:        brokerapi.PlatformAndroid,
		PlatformVersion: apiLevel,
	})
}

// NewOpenRungTelemetryOutboxForIOS opens (or creates) the outbox file fileName
// inside directory (the App Group container) with brokerapi's iOS posting
// header.
func NewOpenRungTelemetryOutboxForIOS(
	directory, fileName, appVersion, osVersion string,
) OpenRungTelemetryOutbox {
	return newOpenRungTelemetryOutbox(directory, fileName, brokerapi.Options{
		AppVersion:      appVersion,
		Platform:        brokerapi.PlatformIOS,
		PlatformVersion: osVersion,
	})
}

func newOpenRungTelemetryOutbox(directory, fileName string, options brokerapi.Options) OpenRungTelemetryOutbox {
	ctx, cancel := context.WithCancel(context.Background())
	o := &openRungTelemetryOutbox{ctx: ctx, cancel: cancel, poster: brokerapi.NewClient(nil, options)}
	queue, err := clienttelemetry.NewOutbox(directory, fileName, o.send)
	if err != nil {
		cancel()
		return nil
	}
	o.queue = queue
	return o
}
func decodeOpenRungTelemetryEvent(raw string) (brokerapi.TelemetryEvent, bool) {
	var event brokerapi.TelemetryEvent
	if json.Unmarshal([]byte(raw), &event) != nil {
		return event, false
	}
	return event, event.EventID != "" && event.Event != "" && event.ClientID != "" && event.SessionID != ""
}
func (o *openRungTelemetryOutbox) Enqueue(raw string) bool {
	event, ok := decodeOpenRungTelemetryEvent(raw)
	return ok && o.queue.Enqueue(event)
}
func (o *openRungTelemetryOutbox) EnqueueBatchJSON(raw string) int32 {
	var items []json.RawMessage
	if json.Unmarshal([]byte(raw), &items) != nil {
		return 0
	}
	var events []clienttelemetry.Event
	for _, item := range items {
		if event, ok := decodeOpenRungTelemetryEvent(string(item)); ok {
			events = append(events, event)
		}
	}
	return int32(o.queue.EnqueueBatch(events))
}
func (o *openRungTelemetryOutbox) ApplySessionAttributes(sessionID, raw string) bool {
	var attributes map[string]string
	if json.Unmarshal([]byte(raw), &attributes) != nil {
		return false
	}
	return o.queue.ApplySessionAttributes(sessionID, attributes)
}
func (o *openRungTelemetryOutbox) PendingCount() int32 { return int32(o.queue.PendingCount()) }
func (o *openRungTelemetryOutbox) flushNextBatch(ctx context.Context, brokerURL string) *OpenRungTelemetryFlushResult {
	sent, pending, err := o.queue.FlushNextBatch(ctx, brokerURL)
	if err != nil {
		if _, urlErr := brokerapi.TelemetryURL(brokerURL); urlErr != nil {
			err = openRungClassifiedError("validation")
		}
	}
	return openRungTelemetryFlushResult(ctx, sent, pending, err)
}
func (o *openRungTelemetryOutbox) sendHeartbeat(ctx context.Context, brokerURL, raw string) *OpenRungTelemetryFlushResult {
	heartbeat, ok := decodeOpenRungTelemetryEvent(raw)
	if !ok {
		return failedOpenRungTelemetryFlushResult(ctx, openRungClassifiedError("validation"), o.PendingCount())
	}
	sent, pending, err := o.queue.SendHeartbeat(ctx, brokerURL, heartbeat)
	if err != nil {
		if _, urlErr := brokerapi.TelemetryURL(brokerURL); urlErr != nil {
			err = openRungClassifiedError("validation")
		}
	}
	return openRungTelemetryFlushResult(ctx, sent, pending, err)
}
func openRungTelemetryFlushResult(ctx context.Context, sent, pending int, err error) *OpenRungTelemetryFlushResult {
	if err != nil {
		return failedOpenRungTelemetryFlushResult(ctx, err, int32(pending))
	}
	return &OpenRungTelemetryFlushResult{outcome: successfulOpenRungBrokerOutcome(), sentCount: int32(sent), pending: int32(pending)}
}
func (o *openRungTelemetryOutbox) Close() { o.cancel(); o.queue.Close() }

// OpenRungTelemetryFlushResult is one FlushNextBatch outcome: the send result
// (the broker binding's error taxonomy), how many events the request carried,
// and how many remain queued afterwards.
type OpenRungTelemetryFlushResult struct {
	outcome   openRungBrokerOutcome
	sentCount int32
	pending   int32
}

func (r *OpenRungTelemetryFlushResult) Succeeded() bool {
	return r != nil && r.outcome.succeeded
}

func (r *OpenRungTelemetryFlushResult) ErrorKind() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorKind
}

func (r *OpenRungTelemetryFlushResult) ErrorText() string {
	if r == nil {
		return ""
	}
	return r.outcome.errorText
}

func (r *OpenRungTelemetryFlushResult) HTTPStatus() int32 {
	if r == nil {
		return 0
	}
	return r.outcome.httpStatus
}

func (r *OpenRungTelemetryFlushResult) RetryAfterMillis() int64 {
	if r == nil {
		return 0
	}
	return r.outcome.retryAfterMillis
}

func (r *OpenRungTelemetryFlushResult) SentCount() int32 {
	if r == nil {
		return 0
	}
	return r.sentCount
}

func (r *OpenRungTelemetryFlushResult) PendingCount() int32 {
	if r == nil {
		return 0
	}
	return r.pending
}

// BeginUpload prepares one single-use, cancelable upload attempt. The
// platforms create one per request and close it from their cancellation
// handlers, so a caller's own cancellation (a terminal flush hitting its
// deadline, tunnel shutdown draining the heartbeat task) is never held
// hostage by an unresponsive broker — the same begin/Close contract the
// per-operation broker transport provides, including its start gate: a Close
// that lands before the request begins wins under the upload's own mutex, and
// the request never starts.
func (o *openRungTelemetryOutbox) BeginUpload() *OpenRungTelemetryUpload {
	ctx, cancel := context.WithCancel(o.ctx)
	return &OpenRungTelemetryUpload{
		outbox:    o,
		ctx:       ctx,
		cancel:    cancel,
		closeDone: make(chan struct{}),
	}
}

// OpenRungTelemetryUpload is one cancelable telemetry upload. Every upload is
// single-use: exactly one of FlushNextBatch/SendHeartbeat may be called. Close
// may run concurrently with that method and is idempotent; it cancels an
// in-flight request, prevents a not-yet-started one from ever starting, and
// waits until any in-flight attempt has returned. The outbox itself stays
// open — a closed upload commits nothing and the events retry later.
type OpenRungTelemetryUpload struct {
	mu sync.Mutex

	outbox *openRungTelemetryOutbox
	ctx    context.Context
	cancel context.CancelFunc

	attempted   bool
	closed      bool
	attemptDone chan struct{}
	closeDone   chan struct{}
}

var errOpenRungTelemetryUploadUsed = errors.New("OpenRung telemetry upload may be invoked only once")

// begin is the start gate: it claims the single attempt under the upload's
// mutex, so it and Close are mutually exclusive — a Close that wins means the
// native request never starts.
func (u *OpenRungTelemetryUpload) begin() (context.Context, chan struct{}, error) {
	if u == nil || u.outbox == nil {
		return nil, nil, openRungClassifiedError("unavailable")
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.closed {
		return nil, nil, context.Canceled
	}
	if u.attempted {
		return nil, nil, errOpenRungTelemetryUploadUsed
	}
	u.attempted = true
	u.attemptDone = make(chan struct{})
	return u.ctx, u.attemptDone, nil
}

// FlushNextBatch uploads at most one batch — the queue head's identity-
// homogeneous prefix under the per-application flow budget — and removes it
// from the outbox on success. An empty queue succeeds with SentCount 0. The
// platforms loop with a fresh upload per batch until PendingCount reaches 0,
// keeping their own cancellation between requests exactly as before.
func (u *OpenRungTelemetryUpload) FlushNextBatch(brokerURL string) *OpenRungTelemetryFlushResult {
	ctx, done, err := u.begin()
	if err != nil {
		return failedOpenRungTelemetryFlushResult(nil, err, 0)
	}
	defer close(done)
	return u.outbox.flushNextBatch(ctx, brokerURL)
}

// SendHeartbeat uploads heartbeatJSON, letting the queue head's identity-
// homogeneous prefix piggyback only when it matches the heartbeat's own
// client/session pair — a historical backlog (or a failure uploading it) must
// never suppress heartbeat cadence, so any other head sends the heartbeat
// alone. Piggybacked events are removed on success; the heartbeat itself is
// never persisted (both platforms rebuild it each cadence). The platforms
// drain what remains with FlushNextBatch uploads afterwards.
func (u *OpenRungTelemetryUpload) SendHeartbeat(
	brokerURL, heartbeatJSON string,
) *OpenRungTelemetryFlushResult {
	ctx, done, err := u.begin()
	if err != nil {
		return failedOpenRungTelemetryFlushResult(nil, err, 0)
	}
	defer close(done)
	return u.outbox.sendHeartbeat(ctx, brokerURL, heartbeatJSON)
}

// Close is idempotent, cancels a blocked request, and waits until any
// in-flight attempt has returned — mirroring the broker operation's Close.
func (u *OpenRungTelemetryUpload) Close() {
	if u == nil {
		return
	}
	u.mu.Lock()
	if u.closeDone == nil {
		u.closeDone = make(chan struct{})
	}
	if u.closed {
		closeDone := u.closeDone
		u.mu.Unlock()
		<-closeDone
		return
	}
	u.closed = true
	if u.cancel != nil {
		u.cancel()
	}
	attemptDone := u.attemptDone
	closeDone := u.closeDone
	u.mu.Unlock()

	if attemptDone != nil {
		<-attemptDone
	}
	close(closeDone)
}

func (o *openRungTelemetryOutbox) send(
	ctx context.Context,
	brokerURL string,
	events []brokerapi.TelemetryEvent,
) error {
	if _, err := brokerapi.TelemetryURL(brokerURL); err != nil {
		return openRungClassifiedError("validation")
	}
	body, err := json.Marshal(struct {
		Events []brokerapi.TelemetryEvent `json:"events"`
	}{Events: events})
	if err != nil {
		return openRungClassifiedError("validation")
	}
	return o.poster.SendTelemetryBatchJSON(ctx, brokerURL, body)
}

func failedOpenRungTelemetryFlushResult(ctx context.Context, err error, pending int32) *OpenRungTelemetryFlushResult {
	if errors.Is(err, clienttelemetry.ErrOutboxClosed) {
		err = context.Canceled
	}
	if errors.Is(err, clienttelemetry.ErrOutboxUnavailable) {
		err = openRungClassifiedError("unavailable")
	}
	if errors.Is(err, errOpenRungTelemetryUploadUsed) {
		// A reused single-use upload is a caller bug, bounded like the broker
		// operation's own reuse error.
		err = openRungClassifiedError("validation")
	}
	// The ctx travels into classification like every sibling failure path in
	// broker_binding.go: a transport error that does not wrap context.Canceled
	// still classifies as cancelled when the upload's own ctx was cancelled.
	return &OpenRungTelemetryFlushResult{
		outcome: classifyOpenRungBrokerError(ctx, err),
		pending: pending,
	}
}
