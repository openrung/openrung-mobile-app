package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/openrung/openrung/brokerapi"
)

const (
	// openRungTelemetryMaxQueued caps the persisted outbox, oldest dropped
	// first — the value both platform outboxes enforced.
	openRungTelemetryMaxQueued = 500
	// openRungTelemetryBatchSize is one upload request's event budget,
	// brokerapi's own maximum.
	openRungTelemetryBatchSize = brokerapi.MaxTelemetryEvents
	// openRungTelemetryCompactThreshold bounds the append-only file: past twice
	// the in-memory cap it is rewritten from the cache, so append cost stays
	// O(1) amortized per event.
	openRungTelemetryCompactThreshold = 2 * openRungTelemetryMaxQueued

	// openRungApplicationConnectionEvent rows carry only the application
	// identity; the broker keeps an hourly per-application count and discards
	// everything else, so their attributes are scrubbed on every load and
	// enqueue (which also scrubs a pre-upgrade backlog before either upload
	// path can put it on the wire).
	openRungApplicationConnectionEvent = "application_connection"
	openRungApplicationCountKey        = "connection_count"
	// openRungMaxReportedFlows is the broker's represented-flow budget per
	// application and upload request (ApplicationConnectionAggregator's
	// MAX_REPORTED_FLOWS).
	openRungMaxReportedFlows = int64(100_000)
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
	FlushNextBatch(brokerURL string) *OpenRungTelemetryFlushResult
	SendHeartbeat(brokerURL, heartbeatJSON string) *OpenRungTelemetryFlushResult
	Close()
}

type openRungTelemetryOutbox struct {
	mu sync.Mutex

	ctx    context.Context
	cancel context.CancelFunc

	path   string
	poster openRungTelemetryPoster

	loaded    bool
	events    []brokerapi.TelemetryEvent
	fileLines int
	closed    bool
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

func newOpenRungTelemetryOutbox(
	directory, fileName string,
	options brokerapi.Options,
) OpenRungTelemetryOutbox {
	if directory == "" || fileName == "" ||
		fileName != filepath.Base(fileName) || fileName == "." || fileName == ".." {
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &openRungTelemetryOutbox{
		ctx:    ctx,
		cancel: cancel,
		path:   filepath.Join(directory, fileName),
		// Passing nil is required: brokerapi selects its shared, opportunistic-
		// ECH transport and verified ordinary-TLS fallback.
		poster: brokerapi.NewClient(nil, options),
	}
}

// Enqueue appends one event (a brokerapi.TelemetryEvent as JSON). An
// undecodable event is dropped and reported false; the outbox itself stays
// usable — telemetry must never take down the reporting path.
func (o *openRungTelemetryOutbox) Enqueue(eventJSON string) bool {
	event, ok := decodeOpenRungTelemetryEvent(eventJSON)
	if !ok {
		return false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.closed {
		return false
	}
	o.appendLocked([]brokerapi.TelemetryEvent{event})
	return true
}

// EnqueueBatchJSON appends every decodable event of a JSON array, oldest
// first, and returns the accepted count. It exists for the platforms'
// pre-file legacy stores (Android's SharedPreferences blob), whose one-time
// import must land through the same cap and sanitization as live events.
func (o *openRungTelemetryOutbox) EnqueueBatchJSON(eventsJSON string) int32 {
	var raw []json.RawMessage
	if err := json.Unmarshal([]byte(eventsJSON), &raw); err != nil {
		return 0
	}
	events := make([]brokerapi.TelemetryEvent, 0, len(raw))
	for _, message := range raw {
		if event, ok := decodeOpenRungTelemetryEvent(string(message)); ok {
			events = append(events, event)
		}
	}
	if len(events) == 0 {
		return 0
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.closed {
		return 0
	}
	o.appendLocked(events)
	return int32(len(events))
}

// ApplySessionAttributes merges attributes (a JSON object of strings, new
// values winning) into every queued event of sessionID — the geo back-patch,
// so events recorded before the public-IP lookup resolved still carry it.
// application_connection rows are never patched; their attributes stay empty.
func (o *openRungTelemetryOutbox) ApplySessionAttributes(
	sessionID, attributesJSON string,
) bool {
	if sessionID == "" {
		return false
	}
	var attributes map[string]string
	if err := json.Unmarshal([]byte(attributesJSON), &attributes); err != nil || len(attributes) == 0 {
		return false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.closed {
		return false
	}
	o.loadLocked()
	changed := false
	for i := range o.events {
		event := &o.events[i]
		if event.SessionID != sessionID || event.Event == openRungApplicationConnectionEvent {
			continue
		}
		if event.Attributes == nil {
			event.Attributes = make(map[string]string, len(attributes))
		}
		for key, value := range attributes {
			if event.Attributes[key] != value {
				event.Attributes[key] = value
				changed = true
			}
		}
	}
	if changed {
		o.rewriteLocked()
	}
	return changed
}

// PendingCount reports the queued event count (loading the file on first use).
func (o *openRungTelemetryOutbox) PendingCount() int32 {
	if o == nil {
		return 0
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.closed {
		return 0
	}
	o.loadLocked()
	return int32(len(o.events))
}

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

// FlushNextBatch uploads at most one batch — the queue head's identity-
// homogeneous prefix under the per-application flow budget — and removes it
// from the outbox on success. An empty queue succeeds with SentCount 0. The
// platforms loop until PendingCount reaches 0, keeping their own cancellation
// between requests exactly as before.
func (o *openRungTelemetryOutbox) FlushNextBatch(brokerURL string) *OpenRungTelemetryFlushResult {
	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return failedOpenRungTelemetryFlushResult(context.Canceled, 0)
	}
	o.loadLocked()
	batch := openRungTelemetryUploadBatch(o.events, openRungTelemetryBatchSize)
	pending := int32(len(o.events))
	ctx := o.ctx
	o.mu.Unlock()

	if len(batch) == 0 {
		return &OpenRungTelemetryFlushResult{
			outcome: successfulOpenRungBrokerOutcome(),
			pending: pending,
		}
	}
	if err := o.send(ctx, brokerURL, batch); err != nil {
		return failedOpenRungTelemetryFlushResult(err, pending)
	}
	return &OpenRungTelemetryFlushResult{
		outcome:   successfulOpenRungBrokerOutcome(),
		sentCount: int32(len(batch)),
		pending:   o.removeSent(batch),
	}
}

// SendHeartbeat uploads heartbeatJSON, letting the queue head's identity-
// homogeneous prefix piggyback only when it matches the heartbeat's own
// client/session pair — a historical backlog (or a failure uploading it) must
// never suppress heartbeat cadence, so any other head sends the heartbeat
// alone. Piggybacked events are removed on success; the heartbeat itself is
// never persisted (both platforms rebuild it each cadence). The platforms
// drain what remains with FlushNextBatch afterwards.
func (o *openRungTelemetryOutbox) SendHeartbeat(
	brokerURL, heartbeatJSON string,
) *OpenRungTelemetryFlushResult {
	heartbeat, ok := decodeOpenRungTelemetryEvent(heartbeatJSON)
	if !ok {
		return failedOpenRungTelemetryFlushResult(
			openRungClassifiedError("validation"),
			o.PendingCount(),
		)
	}

	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return failedOpenRungTelemetryFlushResult(context.Canceled, 0)
	}
	o.loadLocked()
	var piggybacked []brokerapi.TelemetryEvent
	if len(o.events) > 0 &&
		o.events[0].ClientID == heartbeat.ClientID &&
		o.events[0].SessionID == heartbeat.SessionID {
		piggybacked = openRungTelemetryUploadBatch(o.events, openRungTelemetryBatchSize-1)
	}
	pending := int32(len(o.events))
	ctx := o.ctx
	o.mu.Unlock()

	if err := o.send(ctx, brokerURL, append(piggybacked[:len(piggybacked):len(piggybacked)], heartbeat)); err != nil {
		return failedOpenRungTelemetryFlushResult(err, pending)
	}
	if len(piggybacked) > 0 {
		pending = o.removeSent(piggybacked)
	}
	return &OpenRungTelemetryFlushResult{
		outcome:   successfulOpenRungBrokerOutcome(),
		sentCount: int32(len(piggybacked)) + 1,
		pending:   pending,
	}
}

// Close cancels any in-flight upload and rejects further use. It deliberately
// does not touch the outbox file: queued events belong to the next open.
func (o *openRungTelemetryOutbox) Close() {
	if o == nil {
		return
	}
	o.mu.Lock()
	o.closed = true
	o.mu.Unlock()
	if o.cancel != nil {
		o.cancel()
	}
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

func (o *openRungTelemetryOutbox) removeSent(sent []brokerapi.TelemetryEvent) int32 {
	sentIDs := make(map[string]struct{}, len(sent))
	for _, event := range sent {
		sentIDs[event.EventID] = struct{}{}
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	kept := o.events[:0]
	removed := false
	for _, event := range o.events {
		if _, ok := sentIDs[event.EventID]; ok {
			removed = true
			continue
		}
		kept = append(kept, event)
	}
	o.events = kept
	if removed {
		o.rewriteLocked()
	}
	return int32(len(o.events))
}

func (o *openRungTelemetryOutbox) appendLocked(events []brokerapi.TelemetryEvent) {
	o.loadLocked()
	o.events = append(o.events, events...)
	if len(o.events) > openRungTelemetryMaxQueued {
		o.events = append(
			[]brokerapi.TelemetryEvent(nil),
			o.events[len(o.events)-openRungTelemetryMaxQueued:]...,
		)
	}

	var lines []byte
	appendable := true
	for _, event := range events {
		line, err := json.Marshal(event)
		if err != nil {
			appendable = false
			break
		}
		lines = append(lines, line...)
		lines = append(lines, '\n')
	}
	if appendable {
		appendable = appendOpenRungOutboxFile(o.path, lines) == nil
		o.fileLines += len(events)
	}
	// The file may hold more lines than the cap between compactions; a failed
	// append falls back to the same durable rewrite the compaction uses.
	if !appendable || o.fileLines > openRungTelemetryCompactThreshold {
		o.rewriteLocked()
	}
}

// loadLocked populates the cache from the outbox file on first use: NDJSON
// lines (blank, torn, or otherwise undecodable lines skipped) or the
// pre-NDJSON single-JSON-array format, folded in and rewritten as NDJSON — the
// one-time format migration. Loading also re-applies the cap and the
// application_connection scrub to any pre-upgrade backlog, rewriting the file
// whenever what it holds is not exactly what was loaded.
func (o *openRungTelemetryOutbox) loadLocked() {
	if o.loaded {
		return
	}
	o.loaded = true
	raw, err := os.ReadFile(o.path)
	if err != nil || len(raw) == 0 {
		o.events = nil
		o.fileLines = 0
		return
	}

	var parsed []brokerapi.TelemetryEvent
	sourceLines := 0
	if raw[0] == '[' {
		// The pre-NDJSON array format (iOS before 0.3.5). Force the rewrite
		// below even when every event decodes.
		sourceLines = -1
		_ = json.Unmarshal(raw, &parsed)
	} else {
		lines := strings.Split(string(raw), "\n")
		for _, line := range lines {
			if strings.TrimSpace(line) == "" {
				continue
			}
			sourceLines++
			if event, ok := decodeOpenRungTelemetryEvent(line); ok {
				parsed = append(parsed, event)
			}
		}
	}

	events := make([]brokerapi.TelemetryEvent, 0, len(parsed))
	for _, event := range parsed {
		events = append(events, sanitizeOpenRungTelemetryEvent(event))
	}
	if len(events) > openRungTelemetryMaxQueued {
		events = events[len(events)-openRungTelemetryMaxQueued:]
	}
	o.events = events
	o.fileLines = len(events)
	if sourceLines != len(events) {
		o.rewriteLocked()
	}
}

// rewriteLocked lands the cache as one durable file: temp write + atomic
// rename, so a kill mid-rewrite leaves the previous complete file in place.
func (o *openRungTelemetryOutbox) rewriteLocked() {
	var lines []byte
	for _, event := range o.events {
		line, err := json.Marshal(event)
		if err != nil {
			continue
		}
		lines = append(lines, line...)
		lines = append(lines, '\n')
	}
	temp := o.path + ".tmp"
	if err := os.WriteFile(temp, lines, 0o600); err != nil {
		return
	}
	if err := os.Rename(temp, o.path); err != nil {
		_ = os.WriteFile(o.path, lines, 0o600)
		_ = os.Remove(temp)
	}
	o.fileLines = len(o.events)
}

func appendOpenRungOutboxFile(path string, lines []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(lines)
	closeErr := file.Close()
	return errors.Join(writeErr, closeErr)
}

// decodeOpenRungTelemetryEvent accepts one brokerapi.TelemetryEvent, ignoring
// unknown keys (which is what scrubs the removed destination_* fields from a
// pre-upgrade backlog) and rejecting events without the identity fields every
// upload derives its headers from.
func decodeOpenRungTelemetryEvent(eventJSON string) (brokerapi.TelemetryEvent, bool) {
	var event brokerapi.TelemetryEvent
	if err := json.Unmarshal([]byte(eventJSON), &event); err != nil {
		return brokerapi.TelemetryEvent{}, false
	}
	if event.EventID == "" || event.Event == "" || event.ClientID == "" || event.SessionID == "" {
		return brokerapi.TelemetryEvent{}, false
	}
	return sanitizeOpenRungTelemetryEvent(event), true
}

// sanitizeOpenRungTelemetryEvent removes client metadata the broker never
// retains from application-connection records.
func sanitizeOpenRungTelemetryEvent(event brokerapi.TelemetryEvent) brokerapi.TelemetryEvent {
	if event.Event == openRungApplicationConnectionEvent && len(event.Attributes) > 0 {
		event.Attributes = nil
	}
	return event
}

// openRungTelemetryUploadBatch selects one upload request from the first
// event's client/session identity prefix while honoring the broker's
// represented-flow budget per application. The identity boundary is strict:
// brokerapi rejects mixed pairs, and later sessions cannot leapfrog the head
// session. Within that prefix, events that exceed an application's remaining
// budget are deferred along with later events for that application; unrelated
// events may still fill the request.
func openRungTelemetryUploadBatch(
	events []brokerapi.TelemetryEvent,
	limit int,
) []brokerapi.TelemetryEvent {
	if limit <= 0 || len(events) == 0 {
		return nil
	}
	first := events[0]
	representedByApplication := make(map[string]int64)
	deferredApplications := make(map[string]struct{})
	var batch []brokerapi.TelemetryEvent
	for _, event := range events {
		if event.ClientID != first.ClientID || event.SessionID != first.SessionID {
			break
		}
		if len(batch) >= limit {
			break
		}
		if event.Event != openRungApplicationConnectionEvent {
			batch = append(batch, event)
			continue
		}
		application := event.Application
		if _, deferred := deferredApplications[application]; deferred {
			continue
		}
		count := openRungApplicationConnectionCount(event)
		used := representedByApplication[application]
		if count > openRungMaxReportedFlows-used {
			deferredApplications[application] = struct{}{}
			continue
		}
		representedByApplication[application] = used + count
		batch = append(batch, event)
	}
	return batch
}

// openRungApplicationConnectionCount mirrors the broker's compatibility
// behavior for missing or malformed typed counts.
func openRungApplicationConnectionCount(event brokerapi.TelemetryEvent) int64 {
	count, ok := event.Measurements[openRungApplicationCountKey]
	if !ok {
		return 1
	}
	if count < 1 || count > openRungMaxReportedFlows {
		return 1
	}
	return count
}

func failedOpenRungTelemetryFlushResult(err error, pending int32) *OpenRungTelemetryFlushResult {
	return &OpenRungTelemetryFlushResult{
		outcome: classifyOpenRungBrokerError(nil, err),
		pending: pending,
	}
}
