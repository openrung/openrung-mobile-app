package libbox

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/openrung/openrung/brokerapi"
)

const testOutboxFileName = "openrung_telemetry_outbox.jsonl"

// telemetryTestBroker captures every batch the real brokerapi client posts,
// both decoded and as the raw wire bytes (for asserting what must NOT be on
// the wire).
type telemetryTestBroker struct {
	mu      sync.Mutex
	batches [][]brokerapi.TelemetryEvent
	bodies  []string
	status  int
	server  *httptest.Server
}

func newTelemetryTestBroker(t *testing.T) *telemetryTestBroker {
	t.Helper()
	broker := &telemetryTestBroker{status: http.StatusNoContent}
	broker.server = httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/v1/telemetry/events" {
			t.Errorf("unexpected telemetry path %s", request.URL.Path)
		}
		raw, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("reading telemetry body: %v", err)
		}
		var body struct {
			Events []brokerapi.TelemetryEvent `json:"events"`
		}
		if err := json.Unmarshal(raw, &body); err != nil {
			t.Errorf("decoding telemetry batch: %v", err)
		}
		broker.mu.Lock()
		status := broker.status
		if status < http.StatusBadRequest {
			broker.batches = append(broker.batches, body.Events)
			broker.bodies = append(broker.bodies, string(raw))
		}
		broker.mu.Unlock()
		response.WriteHeader(status)
	}))
	t.Cleanup(broker.server.Close)
	return broker
}

func (b *telemetryTestBroker) rawBodies() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.bodies...)
}

func (b *telemetryTestBroker) setStatus(status int) {
	b.mu.Lock()
	b.status = status
	b.mu.Unlock()
}

func (b *telemetryTestBroker) received() [][]brokerapi.TelemetryEvent {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([][]brokerapi.TelemetryEvent(nil), b.batches...)
}

func (b *telemetryTestBroker) receivedEventIDs() []string {
	var ids []string
	for _, batch := range b.received() {
		for _, event := range batch {
			ids = append(ids, event.EventID)
		}
	}
	return ids
}

func testTelemetryOutbox(t *testing.T, directory string) OpenRungTelemetryOutbox {
	t.Helper()
	outbox := NewOpenRungTelemetryOutboxForAndroid(directory, testOutboxFileName, "1.2.3", "34")
	if outbox == nil {
		t.Fatal("outbox constructor rejected valid inputs")
	}
	t.Cleanup(outbox.Close)
	return outbox
}

func testTelemetryEventJSON(t *testing.T, id, event, clientID, sessionID string, extra map[string]any) string {
	t.Helper()
	payload := map[string]any{
		"schema_version": 1,
		"event_id":       id,
		"event":          event,
		"occurred_at":    "2026-08-21T12:00:00Z",
		"client_id":      clientID,
		"session_id":     sessionID,
	}
	for key, value := range extra {
		payload[key] = value
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("encoding test event: %v", err)
	}
	return string(encoded)
}

func drainTelemetryOutbox(t *testing.T, outbox OpenRungTelemetryOutbox, brokerURL string) {
	t.Helper()
	for i := 0; i < 20; i++ {
		result := outbox.FlushNextBatch(brokerURL)
		if !result.Succeeded() {
			t.Fatalf("flush failed: %s (%s)", result.ErrorText(), result.ErrorKind())
		}
		if result.PendingCount() == 0 {
			return
		}
	}
	t.Fatal("outbox did not drain within 20 batches")
}

// TestOpenRungTelemetryOutboxUploadsPreUpgradeNDJSONBacklog is the explicit
// 0.3.5-regression end-to-end test: an outbox file written by the pre-binding
// platform code — including the removed destination_* keys, blank lines, and
// a line torn by a process kill — is uploaded to the broker after the upgrade
// swaps the implementation, through the real binding entry points and the
// real brokerapi client.
func TestOpenRungTelemetryOutboxUploadsPreUpgradeNDJSONBacklog(t *testing.T) {
	directory := t.TempDir()
	preUpgrade := strings.Join([]string{
		// The exact shape the Kotlin outbox wrote (encodeDefaults, explicit
		// nulls), including the destination_* fields an even older version
		// persisted before they were removed from the schema.
		`{"schema_version":1,"event_id":"old-1","event":"connection_failed","occurred_at":"2026-08-01T10:00:00.123Z","client_id":"client-a","session_id":"session-1","relay_id":"relay-9","application_package":null,"application_uid":null,"destination_ip":"203.0.113.9","destination_port":443,"protocol":"tcp","attributes":{"failure_reason":"timeout"},"measurements":{"attempt":2}}`,
		``,
		// An application_connection row whose attributes must be scrubbed.
		`{"schema_version":1,"event_id":"old-2","event":"application_connection","occurred_at":"2026-08-01T10:01:00Z","client_id":"client-a","session_id":"session-1","application_package":"com.example.app","application_uid":10002,"attributes":{"stale":"metadata"},"measurements":{"connection_count":3}}`,
		// A line torn mid-write by a process kill: dropped, never fused or fatal.
		`{"schema_version":1,"event_id":"old-3","event":"connection_end`,
	}, "\n")
	if err := os.WriteFile(filepath.Join(directory, testOutboxFileName), []byte(preUpgrade), 0o600); err != nil {
		t.Fatalf("writing pre-upgrade outbox: %v", err)
	}

	broker := newTelemetryTestBroker(t)
	outbox := testTelemetryOutbox(t, directory)
	if got := outbox.PendingCount(); got != 2 {
		t.Fatalf("pre-upgrade backlog loaded %d events, want 2", got)
	}
	drainTelemetryOutbox(t, outbox, broker.server.URL)

	batches := broker.received()
	if len(batches) != 1 || len(batches[0]) != 2 {
		t.Fatalf("expected the backlog in one batch of 2, got %+v", batches)
	}
	first, second := batches[0][0], batches[0][1]
	if first.EventID != "old-1" || second.EventID != "old-2" {
		t.Fatalf("backlog order changed: %q, %q", first.EventID, second.EventID)
	}
	if first.RelayID != "relay-9" || first.Attributes["failure_reason"] != "timeout" ||
		first.Measurements["attempt"] != 2 {
		t.Fatalf("pre-upgrade event fields lost: %+v", first)
	}
	for _, body := range broker.rawBodies() {
		if strings.Contains(body, "destination_ip") || strings.Contains(body, "destination_port") {
			t.Fatal("removed destination_* fields must not reach the wire after the upgrade")
		}
	}
	if len(second.Attributes) != 0 {
		t.Fatalf("application_connection attributes must be scrubbed: %+v", second.Attributes)
	}
	if second.Application != "com.example.app" || second.Measurements["connection_count"] != 3 {
		t.Fatalf("application identity lost: %+v", second)
	}
	if got := outbox.PendingCount(); got != 0 {
		t.Fatalf("outbox still holds %d events after the drain", got)
	}
}

// TestOpenRungTelemetryOutboxUploadsPreNDJSONArrayBacklog covers the older
// upgrade lineage: the single-JSON-array file iOS wrote before 0.3.5 is folded
// in on first touch, persisted as NDJSON, and uploaded.
func TestOpenRungTelemetryOutboxUploadsPreNDJSONArrayBacklog(t *testing.T) {
	directory := t.TempDir()
	legacy := `[` +
		`{"schema_version":1,"event_id":"array-1","event":"connection_ended","occurred_at":"2026-07-01T08:00:00Z","client_id":"client-b","session_id":"session-7","attributes":{"reason":"user_stop"},"measurements":{"session_duration_ms":1200}},` +
		`{"schema_version":1,"event_id":"array-2","event":"session_heartbeat","occurred_at":"2026-07-01T08:01:00Z","client_id":"client-b","session_id":"session-7"}` +
		`]`
	if err := os.WriteFile(filepath.Join(directory, "outbox.json"), []byte(legacy), 0o600); err != nil {
		t.Fatalf("writing legacy array outbox: %v", err)
	}

	broker := newTelemetryTestBroker(t)
	outbox := NewOpenRungTelemetryOutboxForIOS(directory, "outbox.json", "1.2.3", "26.0")
	if outbox == nil {
		t.Fatal("outbox constructor rejected valid inputs")
	}
	t.Cleanup(outbox.Close)

	if got := outbox.PendingCount(); got != 2 {
		t.Fatalf("legacy array loaded %d events, want 2", got)
	}
	// The load rewrote the array file as NDJSON, so the migration happens once.
	migrated, err := os.ReadFile(filepath.Join(directory, "outbox.json"))
	if err != nil {
		t.Fatalf("reading migrated outbox: %v", err)
	}
	if len(migrated) == 0 || migrated[0] == '[' {
		t.Fatal("legacy array file was not rewritten as NDJSON")
	}
	if got := strings.Count(string(migrated), "\n"); got != 2 {
		t.Fatalf("migrated file holds %d lines, want 2", got)
	}

	drainTelemetryOutbox(t, outbox, broker.server.URL)
	if got := broker.receivedEventIDs(); len(got) != 2 || got[0] != "array-1" || got[1] != "array-2" {
		t.Fatalf("legacy events not uploaded in order: %v", got)
	}
}

// TestOpenRungTelemetryOutboxPersistsAcrossInstances: the everyday power of
// the on-disk outbox — what one process enqueues, the next one uploads.
func TestOpenRungTelemetryOutboxPersistsAcrossInstances(t *testing.T) {
	directory := t.TempDir()
	first := testTelemetryOutbox(t, directory)
	if !first.Enqueue(testTelemetryEventJSON(t, "e-1", "connection_failed", "c", "s", nil)) {
		t.Fatal("enqueue rejected a valid event")
	}
	if !first.Enqueue(testTelemetryEventJSON(t, "e-2", "connection_ended", "c", "s", nil)) {
		t.Fatal("enqueue rejected a valid event")
	}
	first.Close()

	broker := newTelemetryTestBroker(t)
	second := testTelemetryOutbox(t, directory)
	drainTelemetryOutbox(t, second, broker.server.URL)
	if got := broker.receivedEventIDs(); len(got) != 2 || got[0] != "e-1" || got[1] != "e-2" {
		t.Fatalf("persisted events not uploaded in order: %v", got)
	}
}

func TestOpenRungTelemetryOutboxCapsTheQueueOldestFirst(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	for i := 0; i < openRungTelemetryMaxQueued+25; i++ {
		id := fmt.Sprintf("e-%04d", i)
		if !outbox.Enqueue(testTelemetryEventJSON(t, id, "connection_failed", "c", "s", nil)) {
			t.Fatalf("enqueue %s rejected", id)
		}
	}
	if got := outbox.PendingCount(); got != openRungTelemetryMaxQueued {
		t.Fatalf("queue holds %d events, want the %d cap", got, openRungTelemetryMaxQueued)
	}
	// A fresh instance sees the same capped queue: the cap survives the file.
	outbox.Close()
	reopened := testTelemetryOutbox(t, directory)
	if got := reopened.PendingCount(); got != openRungTelemetryMaxQueued {
		t.Fatalf("reloaded queue holds %d events, want %d", got, openRungTelemetryMaxQueued)
	}
}

func TestOpenRungTelemetryOutboxCompactsTheAppendOnlyFile(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	total := openRungTelemetryCompactThreshold + 10
	for i := 0; i < total; i++ {
		outbox.Enqueue(testTelemetryEventJSON(t, fmt.Sprintf("e-%04d", i), "x", "c", "s", nil))
	}
	raw, err := os.ReadFile(filepath.Join(directory, testOutboxFileName))
	if err != nil {
		t.Fatalf("reading outbox file: %v", err)
	}
	lines := strings.Count(string(raw), "\n")
	if lines > openRungTelemetryCompactThreshold {
		t.Fatalf("file holds %d lines; compaction should bound it at %d", lines, openRungTelemetryCompactThreshold)
	}
}

func TestOpenRungTelemetryOutboxAppliesSessionAttributes(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	outbox.Enqueue(testTelemetryEventJSON(t, "mine", "connection_failed", "c", "session-1", map[string]any{
		"attributes": map[string]string{"failure_reason": "timeout"},
	}))
	outbox.Enqueue(testTelemetryEventJSON(t, "other", "connection_failed", "c", "session-2", nil))
	outbox.Enqueue(testTelemetryEventJSON(t, "app", "application_connection", "c", "session-1", map[string]any{
		"application_package": "com.example.app",
	}))

	if !outbox.ApplySessionAttributes("session-1", `{"country":"JP","isp":"Example"}`) {
		t.Fatal("attribute back-patch reported no change")
	}
	outbox.Close()

	broker := newTelemetryTestBroker(t)
	reopened := testTelemetryOutbox(t, directory)
	drainTelemetryOutbox(t, reopened, broker.server.URL)
	events := make(map[string]brokerapi.TelemetryEvent)
	for _, batch := range broker.received() {
		for _, event := range batch {
			events[event.EventID] = event
		}
	}
	if events["mine"].Attributes["country"] != "JP" || events["mine"].Attributes["failure_reason"] != "timeout" {
		t.Fatalf("session event not patched: %+v", events["mine"].Attributes)
	}
	if _, patched := events["other"].Attributes["country"]; patched {
		t.Fatal("another session's event must not be patched")
	}
	if len(events["app"].Attributes) != 0 {
		t.Fatalf("application_connection must stay attribute-free: %+v", events["app"].Attributes)
	}
}

func TestOpenRungTelemetryOutboxBatchesOneIdentityPrefixAtATime(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	outbox.Enqueue(testTelemetryEventJSON(t, "s1-a", "x", "c", "session-1", nil))
	outbox.Enqueue(testTelemetryEventJSON(t, "s1-b", "x", "c", "session-1", nil))
	outbox.Enqueue(testTelemetryEventJSON(t, "s2-a", "x", "c", "session-2", nil))
	outbox.Enqueue(testTelemetryEventJSON(t, "s2-b", "x", "c", "session-2", nil))

	broker := newTelemetryTestBroker(t)
	drainTelemetryOutbox(t, outbox, broker.server.URL)
	batches := broker.received()
	if len(batches) != 2 {
		t.Fatalf("expected 2 identity-homogeneous batches, got %d", len(batches))
	}
	if batches[0][0].SessionID != "session-1" || batches[1][0].SessionID != "session-2" {
		t.Fatalf("batches out of FIFO identity order: %+v", batches)
	}
	for _, batch := range batches {
		for _, event := range batch {
			if event.SessionID != batch[0].SessionID {
				t.Fatalf("mixed identities in one batch: %+v", batch)
			}
		}
	}
}

func TestOpenRungTelemetryOutboxDefersApplicationsOverTheFlowBudget(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	appEvent := func(id string, count int64) string {
		return testTelemetryEventJSON(t, id, "application_connection", "c", "s", map[string]any{
			"application_package": "com.example.heavy",
			"measurements":        map[string]int64{"connection_count": count},
		})
	}
	outbox.Enqueue(appEvent("heavy-1", openRungMaxReportedFlows))
	outbox.Enqueue(appEvent("heavy-2", 5))
	outbox.Enqueue(testTelemetryEventJSON(t, "plain", "connection_failed", "c", "s", nil))

	broker := newTelemetryTestBroker(t)
	first := outbox.FlushNextBatch(broker.server.URL)
	if !first.Succeeded() || first.SentCount() != 2 {
		t.Fatalf("first batch should carry heavy-1 and plain: %+v", broker.received())
	}
	got := broker.receivedEventIDs()
	if len(got) != 2 || got[0] != "heavy-1" || got[1] != "plain" {
		t.Fatalf("budgeted batch selection wrong: %v", got)
	}
	// The deferred application event lands in the next request.
	second := outbox.FlushNextBatch(broker.server.URL)
	if !second.Succeeded() || second.PendingCount() != 0 {
		t.Fatalf("deferred event not drained: %+v", second)
	}
}

func TestOpenRungTelemetryOutboxHeartbeatPiggybacksOnlyItsOwnIdentity(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	outbox.Enqueue(testTelemetryEventJSON(t, "queued-1", "connection_failed", "c", "session-now", nil))
	broker := newTelemetryTestBroker(t)

	heartbeat := testTelemetryEventJSON(t, "hb-1", "session_heartbeat", "c", "session-now", nil)
	result := outbox.SendHeartbeat(broker.server.URL, heartbeat)
	if !result.Succeeded() || result.SentCount() != 2 || result.PendingCount() != 0 {
		t.Fatalf("heartbeat with same-identity head: %+v", result)
	}
	got := broker.receivedEventIDs()
	if len(got) != 2 || got[0] != "queued-1" || got[1] != "hb-1" {
		t.Fatalf("piggyback order wrong: %v", got)
	}

	// A historical head must not delay the cadence: heartbeat goes alone and
	// the backlog stays queued for FlushNextBatch.
	outbox.Enqueue(testTelemetryEventJSON(t, "old-session", "connection_failed", "c", "session-old", nil))
	heartbeat2 := testTelemetryEventJSON(t, "hb-2", "session_heartbeat", "c", "session-new", nil)
	result = outbox.SendHeartbeat(broker.server.URL, heartbeat2)
	if !result.Succeeded() || result.SentCount() != 1 || result.PendingCount() != 1 {
		t.Fatalf("heartbeat with a historical head: %+v", result)
	}
}

func TestOpenRungTelemetryOutboxKeepsEventsWhenTheBrokerFails(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	outbox.Enqueue(testTelemetryEventJSON(t, "kept", "connection_failed", "c", "s", nil))
	broker := newTelemetryTestBroker(t)
	broker.setStatus(http.StatusInternalServerError)

	result := outbox.FlushNextBatch(broker.server.URL)
	if result.Succeeded() {
		t.Fatal("a 500 response must fail the flush")
	}
	if result.ErrorKind() == "" || result.ErrorText() == "" {
		t.Fatalf("failure must carry the broker error taxonomy: %+v", result)
	}
	if got := outbox.PendingCount(); got != 1 {
		t.Fatalf("failed upload must keep the event queued, have %d", got)
	}

	heartbeat := testTelemetryEventJSON(t, "hb", "session_heartbeat", "c", "s", nil)
	if hb := outbox.SendHeartbeat(broker.server.URL, heartbeat); hb.Succeeded() {
		t.Fatal("a 500 response must fail the heartbeat")
	}
	if got := outbox.PendingCount(); got != 1 {
		t.Fatalf("failed heartbeat must not commit piggybacked events, have %d", got)
	}

	broker.setStatus(http.StatusNoContent)
	drainTelemetryOutbox(t, outbox, broker.server.URL)
	if got := outbox.PendingCount(); got != 0 {
		t.Fatalf("recovered flush left %d events queued", got)
	}
}

func TestOpenRungTelemetryOutboxImportsTheLegacyPreferenceBlob(t *testing.T) {
	directory := t.TempDir()
	outbox := testTelemetryOutbox(t, directory)
	blob := `[` +
		testTelemetryEventJSON(t, "prefs-1", "connection_failed", "c", "s", nil) + `,` +
		`{"not":"an event"},` +
		testTelemetryEventJSON(t, "prefs-2", "connection_ended", "c", "s", nil) +
		`]`
	if got := outbox.EnqueueBatchJSON(blob); got != 2 {
		t.Fatalf("imported %d events, want 2", got)
	}
	if got := outbox.EnqueueBatchJSON("not json"); got != 0 {
		t.Fatalf("corrupt blob imported %d events, want 0", got)
	}
	outbox.Close()
	reopened := testTelemetryOutbox(t, directory)
	if got := reopened.PendingCount(); got != 2 {
		t.Fatalf("imported backlog not persisted: %d", got)
	}
}

func TestOpenRungTelemetryOutboxBoundsBadInput(t *testing.T) {
	if NewOpenRungTelemetryOutboxForAndroid("", testOutboxFileName, "1", "34") != nil {
		t.Fatal("empty directory must be rejected")
	}
	if NewOpenRungTelemetryOutboxForAndroid(t.TempDir(), "", "1", "34") != nil {
		t.Fatal("empty file name must be rejected")
	}
	if NewOpenRungTelemetryOutboxForAndroid(t.TempDir(), "../escape.jsonl", "1", "34") != nil {
		t.Fatal("a path-traversing file name must be rejected")
	}

	outbox := testTelemetryOutbox(t, t.TempDir())
	if outbox.Enqueue("not json") {
		t.Fatal("undecodable event must be dropped")
	}
	if outbox.Enqueue(`{"event":"x"}`) {
		t.Fatal("an event without identity fields must be dropped")
	}
	if outbox.ApplySessionAttributes("", `{"a":"b"}`) {
		t.Fatal("empty session id must be rejected")
	}
	if outbox.ApplySessionAttributes("s", "not json") {
		t.Fatal("undecodable attributes must be rejected")
	}
	if result := outbox.FlushNextBatch(""); result.Succeeded() {
		// An empty queue would succeed regardless of the URL; queue one first.
		t.Log("empty queue short-circuits before URL validation")
	}
	outbox.Enqueue(testTelemetryEventJSON(t, "e", "x", "c", "s", nil))
	if result := outbox.FlushNextBatch("not a url"); result.Succeeded() || result.ErrorKind() != "validation" {
		t.Fatalf("invalid broker URL must fail validation: %+v", result)
	}
}
