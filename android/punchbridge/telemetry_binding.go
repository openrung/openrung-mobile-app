package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

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
	BeginUpload() *OpenRungTelemetryUpload
	Close()
}

type openRungTelemetryOutbox struct {
	mu sync.Mutex

	ctx    context.Context
	cancel context.CancelFunc

	path   string
	poster openRungTelemetryPoster

	// lockFile holds the advisory cross-process lock on the outbox for this
	// outbox's lifetime (see loadLocked); nil until the first successful load.
	lockFile *os.File

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
	if o.closed || !o.loadLocked() {
		return false
	}
	o.appendLocked([]brokerapi.TelemetryEvent{event})
	return true
}

// EnqueueBatchJSON appends every decodable event of a JSON array, oldest
// first. It exists for the platforms' pre-file legacy stores (Android's
// SharedPreferences blob), whose one-time import must land through the same
// cap and sanitization as live events — and whose only durable copy the
// caller deletes on this method's word. The return value is therefore a
// three-way answer: the accepted count once the events are DURABLY persisted
// to the outbox file, 0 for a blob that holds nothing importable (the import
// is complete; the caller may clear its store), and -1 when the events could
// not be durably written (closed outbox, unwritable directory) — the caller
// must keep its copy and retry on the next open.
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
	if o.closed || !o.loadLocked() {
		return -1
	}
	if !o.appendLocked(events) {
		// The events stay in the in-memory queue (a later flush may still
		// upload them), but nothing durable landed: the caller keeps its copy.
		return -1
	}
	if syncOpenRungOutboxFile(o.path) != nil {
		// The append landed only in the page cache; a crash could still lose
		// it, so the caller must keep its copy. The events remain queued.
		return -1
	}
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
	if o.closed || !o.loadLocked() {
		return false
	}
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
	if o.closed || !o.loadLocked() {
		return 0
	}
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

func (o *openRungTelemetryOutbox) flushNextBatch(ctx context.Context, brokerURL string) *OpenRungTelemetryFlushResult {
	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return failedOpenRungTelemetryFlushResult(ctx, context.Canceled, 0)
	}
	if !o.loadLocked() {
		// The queue is unreadable this attempt (transient file error, or
		// another process owns the outbox): fail the flush rather than report
		// an empty, drained queue.
		o.mu.Unlock()
		return failedOpenRungTelemetryFlushResult(ctx, openRungClassifiedError("unavailable"), 0)
	}
	batch := openRungTelemetryUploadBatch(o.events, openRungTelemetryBatchSize)
	pending := int32(len(o.events))
	o.mu.Unlock()

	if len(batch) == 0 {
		return &OpenRungTelemetryFlushResult{
			outcome: successfulOpenRungBrokerOutcome(),
			pending: pending,
		}
	}
	if err := o.send(ctx, brokerURL, batch); err != nil {
		return failedOpenRungTelemetryFlushResult(ctx, err, pending)
	}
	return &OpenRungTelemetryFlushResult{
		outcome:   successfulOpenRungBrokerOutcome(),
		sentCount: int32(len(batch)),
		pending:   o.removeSent(batch),
	}
}

func (o *openRungTelemetryOutbox) sendHeartbeat(
	ctx context.Context,
	brokerURL, heartbeatJSON string,
) *OpenRungTelemetryFlushResult {
	heartbeat, ok := decodeOpenRungTelemetryEvent(heartbeatJSON)
	if !ok {
		return failedOpenRungTelemetryFlushResult(
			ctx,
			openRungClassifiedError("validation"),
			o.PendingCount(),
		)
	}

	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return failedOpenRungTelemetryFlushResult(ctx, context.Canceled, 0)
	}
	// A failed load must not block the cadence: the heartbeat goes alone and
	// the queue is retried by the next operation.
	_ = o.loadLocked()
	var piggybacked []brokerapi.TelemetryEvent
	if len(o.events) > 0 &&
		o.events[0].ClientID == heartbeat.ClientID &&
		o.events[0].SessionID == heartbeat.SessionID {
		piggybacked = openRungTelemetryUploadBatch(o.events, openRungTelemetryBatchSize-1)
	}
	pending := int32(len(o.events))
	o.mu.Unlock()

	if err := o.send(ctx, brokerURL, append(piggybacked[:len(piggybacked):len(piggybacked)], heartbeat)); err != nil {
		return failedOpenRungTelemetryFlushResult(ctx, err, pending)
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

// Close cancels any in-flight upload, rejects further use, and releases the
// cross-process file lock. It deliberately does not touch the outbox file:
// queued events belong to the next open.
func (o *openRungTelemetryOutbox) Close() {
	if o == nil {
		return
	}
	o.mu.Lock()
	o.closed = true
	if o.lockFile != nil {
		_ = syscall.Flock(int(o.lockFile.Fd()), syscall.LOCK_UN)
		_ = o.lockFile.Close()
		o.lockFile = nil
	}
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

// appendLocked queues events and lands them on disk, reporting whether the
// events are now durably persisted (directly appended, or via the rewrite a
// failed append and the compaction both fall back to).
func (o *openRungTelemetryOutbox) appendLocked(events []brokerapi.TelemetryEvent) bool {
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
		return o.rewriteLocked()
	}
	return true
}

// loadLocked populates the cache from the outbox file on first use: NDJSON
// lines (blank, torn, or otherwise undecodable lines skipped) or the
// pre-NDJSON single-JSON-array format, folded in and rewritten as NDJSON — the
// one-time format migration. Loading also re-applies the cap and the
// application_connection scrub to any pre-upgrade backlog, rewriting the file
// whenever what it holds is not exactly what was loaded. It reports false when
// the outbox is unavailable this operation — the file is unreadable, or
// another process owns it — in which case nothing is cached and the next
// operation retries.
func (o *openRungTelemetryOutbox) loadLocked() bool {
	if o.loaded {
		return true
	}
	// One process owns the outbox file for the outbox's lifetime. The lock is
	// advisory, taken on the first load, and released by Close or process
	// death. A second process of the same app (the iOS app beside its
	// PacketTunnel extension shares the App Group container) degrades to an
	// unavailable outbox instead of overwriting the owner's queue with its own
	// stale cache — the coordination the platform outboxes' NSFileCoordinator
	// previously provided.
	if o.lockFile == nil {
		lock, err := os.OpenFile(o.path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			return false
		}
		if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			_ = lock.Close()
			return false
		}
		o.lockFile = lock
	}
	raw, err := os.ReadFile(o.path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		// A transient read failure must not read as an empty queue: a later
		// rewrite would replace the intact backlog on disk with the empty
		// cache. Stay unloaded so the next operation retries.
		return false
	}
	o.loaded = true
	if err != nil || len(raw) == 0 {
		o.events = nil
		o.fileLines = 0
		return true
	}

	var parsed []brokerapi.TelemetryEvent
	dirty := false
	sourceLines := 0
	if raw[0] == '[' {
		// The pre-NDJSON array format (iOS before 0.3.5), validated element by
		// element exactly like live enqueues — a row without the identity
		// fields can never anchor (and permanently poison) an upload batch,
		// and one undecodable element cannot discard the decodable remainder.
		// Always rewritten as NDJSON below: the one-time format migration.
		dirty = true
		var rawEvents []json.RawMessage
		if json.Unmarshal(raw, &rawEvents) == nil {
			for _, message := range rawEvents {
				if event, ok := decodeOpenRungTelemetryEvent(string(message)); ok {
					parsed = append(parsed, event)
				}
			}
		}
	} else {
		if raw[len(raw)-1] != '\n' {
			// An unterminated tail line that still decodes would fuse with the
			// next append into one undecodable line, losing both events; the
			// rewrite below re-terminates it (the torn-tail repair the platform
			// outboxes performed before every append).
			dirty = true
		}
		lines := strings.Split(string(raw), "\n")
		for _, line := range lines {
			if strings.TrimSpace(line) == "" {
				continue
			}
			sourceLines++
			if event, ok := decodeOpenRungTelemetryEvent(line); ok {
				if openRungTelemetryLineNeedsScrub(line, event) {
					// The decode scrubbed data the stored line still carries;
					// persist the scrub instead of leaving it on disk.
					dirty = true
				}
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
	if dirty || sourceLines != len(events) {
		o.rewriteLocked()
	}
	return true
}

// rewriteLocked lands the cache as one durable file — temp write, fsync,
// atomic rename, so a kill mid-rewrite leaves the previous complete file in
// place — and reports whether the file now holds the cache.
func (o *openRungTelemetryOutbox) rewriteLocked() bool {
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
	file, err := os.OpenFile(temp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return false
	}
	_, writeErr := file.Write(lines)
	syncErr := file.Sync()
	closeErr := file.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		_ = os.Remove(temp)
		return false
	}
	if err := os.Rename(temp, o.path); err != nil {
		// No in-place fallback: overwriting the live file directly is not
		// atomic, and a false answer already means "the file does not hold the
		// cache" to every caller.
		_ = os.Remove(temp)
		return false
	}
	_ = syncOpenRungDir(filepath.Dir(o.path))
	o.fileLines = len(o.events)
	return true
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
			batch = append(batch, cloneOpenRungTelemetryEvent(event))
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
		batch = append(batch, cloneOpenRungTelemetryEvent(event))
	}
	return batch
}

// cloneOpenRungTelemetryEvent gives a batch entry its own attribute and
// measurement maps: the send marshals the batch outside the outbox lock, and
// sharing map headers with the live queue would race the geo back-patch's
// under-lock writes — a fatal concurrent map access.
func cloneOpenRungTelemetryEvent(event brokerapi.TelemetryEvent) brokerapi.TelemetryEvent {
	event.Attributes = maps.Clone(event.Attributes)
	event.Measurements = maps.Clone(event.Measurements)
	return event
}

// openRungTelemetryLineNeedsScrub reports whether a stored line still carries
// data the decode scrubbed from the loaded event — the removed destination_*
// and protocol keys any pre-upgrade event may hold (their JSON null spellings
// included), or attributes on an application_connection row — so the load can
// persist the scrub instead of leaving the data on disk indefinitely.
func openRungTelemetryLineNeedsScrub(line string, event brokerapi.TelemetryEvent) bool {
	var probe struct {
		Attributes      map[string]json.RawMessage `json:"attributes"`
		DestinationIP   json.RawMessage            `json:"destination_ip"`
		DestinationPort json.RawMessage            `json:"destination_port"`
		Protocol        json.RawMessage            `json:"protocol"`
	}
	if json.Unmarshal([]byte(line), &probe) != nil {
		return false
	}
	if probe.DestinationIP != nil || probe.DestinationPort != nil || probe.Protocol != nil {
		return true
	}
	return event.Event == openRungApplicationConnectionEvent && len(probe.Attributes) > 0
}

// syncOpenRungOutboxFile flushes the outbox file and its directory entry to
// stable storage — the legacy import deletes its only other copy on this
// promise, so "accepted" must survive a power loss.
func syncOpenRungOutboxFile(path string) error {
	file, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(syncErr, closeErr); err != nil {
		return err
	}
	return syncOpenRungDir(filepath.Dir(path))
}

func syncOpenRungDir(dir string) error {
	handle, err := os.Open(dir)
	if err != nil {
		return err
	}
	syncErr := handle.Sync()
	closeErr := handle.Close()
	return errors.Join(syncErr, closeErr)
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

func failedOpenRungTelemetryFlushResult(ctx context.Context, err error, pending int32) *OpenRungTelemetryFlushResult {
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
