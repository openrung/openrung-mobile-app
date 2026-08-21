package libbox

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// The vendored contract vectors this binding is a consumer of, plus the
// binding-input fixture that ties the platform adapters to it. The vector
// version is pinned like every other suite's: a bump upstream means revisiting
// this one too.
const (
	classificationVectorsPath      = "../../testdata/contract/classification.json"
	classificationBindingInputPath = "../../testdata/classification-binding-inputs.json"
	classificationVectorsVersion   = 2
)

type classificationVectorFile struct {
	Version int `json:"version"`
	Kinds   map[string]struct {
		Suites []string `json:"suites"`
	} `json:"kinds"`
	Cases []classificationVectorCase `json:"cases"`
}

type classificationVectorCase struct {
	ID       string   `json:"id"`
	Kind     string   `json:"kind"`
	Platform string   `json:"platform"`
	Suites   []string `json:"suites"`
	Expect   string   `json:"expect"`
}

type classificationBindingInputFile struct {
	ContractVersion int                       `json:"contract_version"`
	Inputs          map[string]map[string]any `json:"inputs"`
}

// classificationErrnoSymbols resolves the vectors' POSIX errno symbols
// locally, as the contract requires of every suite: numbers differ per kernel,
// and in production the adapter and this binding are always compiled for the
// same platform.
var classificationErrnoSymbols = map[string]syscall.Errno{
	"ECONNREFUSED": syscall.ECONNREFUSED,
	"ECONNRESET":   syscall.ECONNRESET,
	"ENETUNREACH":  syscall.ENETUNREACH,
	"EHOSTUNREACH": syscall.EHOSTUNREACH,
	"ETIMEDOUT":    syscall.ETIMEDOUT,
	"EACCES":       syscall.EACCES,
	"EPERM":        syscall.EPERM,
	"EPIPE":        syscall.EPIPE,
}

func loadClassificationVectors(t *testing.T) classificationVectorFile {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(classificationVectorsPath))
	if err != nil {
		t.Fatalf("reading contract vectors: %v", err)
	}
	var vectors classificationVectorFile
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatalf("decoding contract vectors: %v", err)
	}
	if vectors.Version != classificationVectorsVersion {
		t.Fatalf(
			"contract vectors are version %d, this suite was written for %d; revisit it",
			vectors.Version,
			classificationVectorsVersion,
		)
	}
	return vectors
}

func loadClassificationBindingInputs(t *testing.T) classificationBindingInputFile {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(classificationBindingInputPath))
	if err != nil {
		t.Fatalf("reading binding-input fixture: %v", err)
	}
	var inputs classificationBindingInputFile
	if err := json.Unmarshal(raw, &inputs); err != nil {
		t.Fatalf("decoding binding-input fixture: %v", err)
	}
	if inputs.ContractVersion != classificationVectorsVersion {
		t.Fatalf(
			"binding-input fixture is for contract version %d, want %d",
			inputs.ContractVersion,
			classificationVectorsVersion,
		)
	}
	return inputs
}

// suitesFor mirrors the platform suites' rule: the kind's list, narrowed by
// the row's own when it has one.
func (f classificationVectorFile) suitesFor(row classificationVectorCase) []string {
	if row.Suites != nil {
		return row.Suites
	}
	return f.Kinds[row.Kind].Suites
}

func isMobileClassificationRow(vectors classificationVectorFile, row classificationVectorCase) bool {
	suites := vectors.suitesFor(row)
	for _, suite := range suites {
		if suite == "kotlin" || suite == "swift" {
			return true
		}
	}
	return false
}

// wireClassificationInput turns one fixture entry into the binding's wire
// JSON, resolving errno_symbol to this platform's number — the same transform
// the Kotlin and Swift suites apply before comparing their adapters' output.
func wireClassificationInput(t *testing.T, id string, entry map[string]any) string {
	t.Helper()
	wire := make(map[string]any, len(entry))
	for key, value := range entry {
		if key != "errno_symbol" {
			wire[key] = value
			continue
		}
		symbol, ok := value.(string)
		if !ok {
			t.Fatalf("%s: errno_symbol is not a string", id)
		}
		errno, ok := classificationErrnoSymbols[symbol]
		if !ok {
			t.Fatalf("%s: unknown errno symbol %q", id, symbol)
		}
		wire["errno"] = int(errno)
	}
	encoded, err := json.Marshal(wire)
	if err != nil {
		t.Fatalf("%s: encoding wire input: %v", id, err)
	}
	return string(encoded)
}

// TestOpenRungClassifyFailureMatchesTheContractVectors composes with the
// Kotlin and Swift suites: they pin platform exception → fixture input, this
// pins fixture input → token through the real binding entry point, so every
// mobile-claimed vector row runs against the shared classifier end to end.
// Windows rows are skipped for the platform suites' reason (only a Windows
// network stack produces Winsock numbers; neither mobile OS does), and the
// 'none' kind never reaches the binding — the adapters return "" for a null
// error before extracting anything, which the Kotlin suite pins.
func TestOpenRungClassifyFailureMatchesTheContractVectors(t *testing.T) {
	vectors := loadClassificationVectors(t)
	fixture := loadClassificationBindingInputs(t)

	covered := make(map[string]bool, len(fixture.Inputs))
	ran := 0
	for _, row := range vectors.Cases {
		if !isMobileClassificationRow(vectors, row) || row.Platform == "windows" {
			continue
		}
		if row.Kind == "none" {
			continue
		}
		entry, ok := fixture.Inputs[row.ID]
		if !ok {
			t.Errorf("%s: mobile-claimed row has no binding-input fixture entry", row.ID)
			continue
		}
		covered[row.ID] = true
		ran++
		if got := OpenRungClassifyFailure(wireClassificationInput(t, row.ID, entry)); got != row.Expect {
			t.Errorf("%s: classified %q, want %q", row.ID, got, row.Expect)
		}
	}
	// A suite that silently matched no row would pass while asserting nothing.
	if ran < 25 {
		t.Fatalf("only %d rows ran; the vectors or the kind mapping changed shape", ran)
	}
	for id := range fixture.Inputs {
		if !covered[id] {
			t.Errorf("%s: fixture entry matches no mobile-claimed vector row; remove or fix it", id)
		}
	}
}

// TestOpenRungClassifyFailureBrokerKinds pins the projection the platforms'
// hand-written classifyNativeFailure/failureReason tables used to own: every
// bounded broker-binding kind, including the two platform-only ones
// (unavailable, decode) and a future kind, lands on the same token.
func TestOpenRungClassifyFailureBrokerKinds(t *testing.T) {
	cases := []struct {
		kind       string
		httpStatus int
		want       string
	}{
		{kind: "cancelled", want: "cancelled"},
		{kind: "timeout", want: "timeout"},
		{kind: "rate_limited", want: "rate_limited"},
		{kind: "http_status", httpStatus: 429, want: "rate_limited"},
		{kind: "http_status", httpStatus: 503, want: "http_503"},
		{kind: "http_status", want: "unknown"},
		{kind: "dns", want: "dns_failure"},
		{kind: "tls", want: "tls_handshake"},
		{kind: "network", want: "network_unreachable"},
		{kind: "verification", want: "unknown"},
		{kind: "validation", want: "unknown"},
		{kind: "unknown", want: "unknown"},
		{kind: "unavailable", want: "unknown"},
		{kind: "decode", want: "unknown"},
		{kind: "future_kind", want: "unknown"},
	}
	for _, testCase := range cases {
		input := map[string]any{"broker_kind": testCase.kind}
		if testCase.httpStatus > 0 {
			input["http_status"] = testCase.httpStatus
		}
		encoded, err := json.Marshal(input)
		if err != nil {
			t.Fatalf("encoding input: %v", err)
		}
		if got := OpenRungClassifyFailure(string(encoded)); got != testCase.want {
			t.Errorf(
				"broker kind %q (status %d): classified %q, want %q",
				testCase.kind,
				testCase.httpStatus,
				got,
				testCase.want,
			)
		}
	}
}

// TestOpenRungClassifyFailurePrecedence pins how the shared ladder orders
// chains that carry several facts at once — the scenarios the platform ladders
// used to decide themselves.
func TestOpenRungClassifyFailurePrecedence(t *testing.T) {
	refused := int(syscall.ECONNREFUSED)
	cases := []struct {
		name  string
		input map[string]any
		want  string
	}{
		{
			name:  "cancellation wins over an errno in the same chain",
			input: map[string]any{"cancelled": true, "errno": refused},
			want:  "cancelled",
		},
		{
			name:  "a selection sentinel wins over a generic timeout",
			input: map[string]any{"selection": "no_usable_relay", "timeout": true},
			want:  "no_usable_relay",
		},
		{
			name:  "a broker status wins over a DNS fact deeper in the chain",
			input: map[string]any{"http_status": 503, "dns": true},
			want:  "http_503",
		},
		{
			name:  "DNS wins over a timeout: the more actionable signal",
			input: map[string]any{"dns": true, "timeout": true},
			want:  "dns_failure",
		},
		{
			name:  "TLS wins over a timeout in the same chain",
			input: map[string]any{"tls": true, "timeout": true},
			want:  "tls_handshake",
		},
		{
			name:  "permission wins over engine-exit (revoked consent during engine start)",
			input: map[string]any{"permission_denied": true, "process_exited": true},
			want:  "permission_denied",
		},
		{
			name:  "an errno root cause wins over an engine-exit wrapper",
			input: map[string]any{"errno": refused, "process_exited": true},
			want:  "connection_refused",
		},
		{
			name:  "a native broker network failure outranks a stray platform errno",
			input: map[string]any{"broker_kind": "network", "errno": refused},
			want:  "network_unreachable",
		},
		{
			// The deliberately unmapped EPIPE reports Timeout() == false; the
			// binding joins the timeout fact ahead of the errno so it cannot
			// shadow a real timeout at the ladder's generic-timeout rung.
			name:  "an unmapped errno does not shadow a timeout in the same chain",
			input: map[string]any{"errno": int(syscall.EPIPE), "timeout": true},
			want:  "timeout",
		},
	}
	for _, testCase := range cases {
		encoded, err := json.Marshal(testCase.input)
		if err != nil {
			t.Fatalf("%s: encoding input: %v", testCase.name, err)
		}
		if got := OpenRungClassifyFailure(string(encoded)); got != testCase.want {
			t.Errorf("%s: classified %q, want %q", testCase.name, got, testCase.want)
		}
	}
}

// TestOpenRungClassifyFailureBoundsBadInput: the classifier runs on the
// telemetry reporting path, so anything undescribable degrades to the bounded
// residual instead of failing the report.
func TestOpenRungClassifyFailureBoundsBadInput(t *testing.T) {
	cases := []struct {
		name  string
		input string
	}{
		{name: "empty facts", input: `{}`},
		{name: "not JSON", input: `not json`},
		{name: "empty string", input: ``},
		{name: "unknown field", input: `{"reason": "connection_refused"}`},
		{name: "trailing data", input: `{"timeout": true} {}`},
		{name: "unknown selection sentinel", input: `{"selection": "no_such_sentinel"}`},
		{name: "negative errno", input: `{"errno": -1}`},
		{name: "wrong field type", input: `{"errno": "ECONNREFUSED"}`},
	}
	for _, testCase := range cases {
		if got := OpenRungClassifyFailure(testCase.input); got != "unknown" {
			t.Errorf("%s: classified %q, want %q", testCase.name, got, "unknown")
		}
	}
}

func TestOpenRungFailureDetailBoundsTheMessage(t *testing.T) {
	if got := OpenRungFailureDetail(""); got != "" {
		t.Errorf("empty message: got %q, want empty", got)
	}
	short := "connect timed out"
	if got := OpenRungFailureDetail(short); got != short {
		t.Errorf("short message: got %q, want it unchanged", got)
	}
	exactly256 := strings.Repeat("a", 256)
	if got := OpenRungFailureDetail(exactly256); got != exactly256 {
		t.Errorf("256-byte message: got %d bytes, want it unchanged", len(got))
	}
	if got := OpenRungFailureDetail(strings.Repeat("a", 300)); len(got) != 256 {
		t.Errorf("300-byte message: got %d bytes, want 256", len(got))
	}
	// 254 ASCII bytes + a 4-byte emoji = 258 bytes; a naive 256-byte cut would
	// split the emoji.
	base := strings.Repeat("a", 254)
	if got := OpenRungFailureDetail(base + "😀"); got != base {
		t.Errorf("rune boundary: got %q, want the emoji dropped whole", got)
	}
}
