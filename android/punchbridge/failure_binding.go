package libbox

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/openrung/openrung/connectcore/client"
	"github.com/openrung/openrung/connectcore/clienttelemetry"
)

// openRungFailureInput is one platform-described connect failure: the facts a
// Kotlin/Swift adapter extracted from its exception chain, with every token
// decision left to the shared classifier. Fields are independent — a chain can
// carry several facts at once (a revoked-permission SecurityException inside an
// engine-start wrapper), and connectcore's ladder, not the adapter, decides
// which one wins. The errno is the raw platform number: the binding is always
// compiled for the same platform that raised it (bionic for the AAR, darwin
// for the XCFramework), so syscall resolves it to the same condition.
type openRungFailureInput struct {
	// Cancelled reports local intent: the user stopped the connect, or the
	// enclosing task/coroutine was cancelled.
	Cancelled bool `json:"cancelled"`
	// Selection is the relay-selection sentinel the connect pipeline raised,
	// named by the contract vectors' sentinel vocabulary: no_relays_available,
	// relay_not_in_list, no_relay_in_country, or no_usable_relay.
	Selection string `json:"selection"`
	// HTTPStatus is a broker/CDN status carried by the failure; 0 means none.
	HTTPStatus int `json:"http_status"`
	// BrokerKind is the bounded errorKind of a failed native broker operation
	// (broker_binding.go's own vocabulary, mirrored by the platforms'
	// BrokerNativeFailureKind).
	BrokerKind string `json:"broker_kind"`
	// Errno is the raw platform errno surfaced by a socket failure; 0 means none.
	Errno int `json:"errno"`
	// DNS reports a name-resolution failure that carries no errno.
	DNS bool `json:"dns"`
	// TLS reports a TLS handshake or certificate rejection of any shape.
	TLS bool `json:"tls"`
	// PermissionDenied reports an OS refusal with no errno: revoked VPN
	// consent, or a denied tunnel-device open. EACCES/EPERM arrive as Errno.
	PermissionDenied bool `json:"permission_denied"`
	// ProcessExited reports that the embedded tunnel engine died on arrival.
	ProcessExited bool `json:"process_exited"`
	// Timeout reports a generic i/o timeout that carries no errno.
	Timeout bool `json:"timeout"`
}

// errOpenRungUnclassifiedFailure matches no ladder rung, so it classifies as
// the bounded "unknown" residual.
var errOpenRungUnclassifiedFailure = errors.New("unclassified platform failure")

// OpenRungClassifyFailure maps one platform-described connect failure to the
// stable lowercase snake_case failure_reason token the broker's "Failure
// reasons" dashboard groups by. The input is one JSON object in the
// openRungFailureInput shape; the token comes from connectcore's shared
// classifier (clienttelemetry.ClassifyError), which every Go client uses, so
// the mobile platforms and the desktop/CLI clients file the same failure under
// the same token by construction. A call always describes an existing error,
// so the result is never ""; anything undescribable — including a malformed
// input, which must degrade rather than take down the reporting path — stays
// in the bounded "unknown" bucket. The nil-error → "" rule stays in the
// platform adapters, which never call the binding without an error in hand.
func OpenRungClassifyFailure(inputJSON string) string {
	input, err := decodeOpenRungFailureInput(inputJSON)
	if err != nil {
		return "unknown"
	}
	return clienttelemetry.ClassifyError(openRungFailureError(input))
}

// OpenRungFailureDetail bounds one platform-selected failure message to the
// broker's per-attribute limit (256 UTF-8 bytes, cut on a rune boundary),
// which is clienttelemetry.ErrorDetail's policy. Choosing WHICH message —
// the root cause's, a wrapper's — stays with the platform, whose exception
// chain the binding cannot see.
func OpenRungFailureDetail(text string) string {
	if text == "" {
		return ""
	}
	return clienttelemetry.ErrorDetail(errors.New(text))
}

func decodeOpenRungFailureInput(inputJSON string) (openRungFailureInput, error) {
	var input openRungFailureInput
	decoder := json.NewDecoder(strings.NewReader(inputJSON))
	// The adapters ship in the same bundle as this binding, so an unknown
	// field is drift, not forward compatibility.
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return openRungFailureInput{}, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return openRungFailureInput{}, errors.New("trailing data after failure input")
	}
	return input, nil
}

// openRungFailureError reconstructs the input as one Go error chain and lets
// connectcore's ladder order the facts. Two placements are deliberate, because
// the ladder's generic-timeout rung binds the shallowest net.Error in the
// chain (see clienttelemetry/classify.go): the broker-kind error precedes the
// raw errno so a native broker failure keeps outranking a stray platform errno
// (the platform ladders' old rung order), and the generic-timeout fact
// precedes the raw errno so an unmapped errno reporting Timeout() == false
// (EPIPE) cannot shadow a real timeout in the same chain.
func openRungFailureError(input openRungFailureInput) error {
	var facts []error
	if input.Cancelled {
		facts = append(facts, context.Canceled)
	}
	if sentinel := openRungSelectionError(input.Selection); sentinel != nil {
		facts = append(facts, sentinel)
	}
	if input.HTTPStatus > 0 {
		facts = append(facts, &openRungFailureStatusError{status: input.HTTPStatus})
	}
	if kind := strings.TrimSpace(input.BrokerKind); kind != "" {
		facts = append(facts, openRungBrokerKindError(kind, input.HTTPStatus))
	}
	if input.Timeout {
		facts = append(facts, os.ErrDeadlineExceeded)
	}
	if input.Errno > 0 {
		facts = append(facts, syscall.Errno(input.Errno))
	}
	if input.DNS {
		facts = append(facts, &net.DNSError{Err: "name resolution failed"})
	}
	if input.TLS {
		facts = append(facts, tls.RecordHeaderError{Msg: "platform TLS failure"})
	}
	if input.PermissionDenied {
		facts = append(facts, os.ErrPermission)
	}
	if input.ProcessExited {
		// The ladder's engine-exit rung matches *exec.ExitError, the shape a
		// sing-box subprocess death has on desktop; a zero ProcessState is the
		// embedded engine's stand-in for it.
		facts = append(facts, &exec.ExitError{ProcessState: &os.ProcessState{}})
	}
	if len(facts) == 0 {
		return errOpenRungUnclassifiedFailure
	}
	return errors.Join(facts...)
}

func openRungSelectionError(selection string) error {
	switch selection {
	case "":
		return nil
	case "no_relays_available":
		return client.ErrNoRelaysAvailable
	case "relay_not_in_list":
		return client.ErrRelayNotInList
	case "no_relay_in_country":
		return client.ErrNoRelayInCountry
	case "no_usable_relay":
		return client.ErrNoUsableRelay
	default:
		return errOpenRungUnclassifiedFailure
	}
}

// openRungBrokerKindError translates one bounded broker-binding error kind
// into the Go error whose ladder rung produces the token the platforms'
// hand-written projections used to choose: dns → dns_failure, tls →
// tls_handshake, network → network_unreachable (via the errno rung), 429 and
// rate_limited → rate_limited, any other status → http_<status>. verification,
// validation, unavailable, decode, unknown, a status-less http_status, and any
// future kind all stay in the bounded unknown bucket.
func openRungBrokerKindError(kind string, httpStatus int) error {
	switch kind {
	case "cancelled":
		return context.Canceled
	case "timeout":
		return os.ErrDeadlineExceeded
	case "rate_limited":
		return &openRungFailureStatusError{status: http.StatusTooManyRequests}
	case "http_status":
		if httpStatus > 0 {
			return &openRungFailureStatusError{status: httpStatus}
		}
		return errOpenRungUnclassifiedFailure
	case "dns":
		return &net.DNSError{Err: "native broker DNS failure"}
	case "tls":
		return tls.RecordHeaderError{Msg: "native broker TLS failure"}
	case "network":
		return syscall.ENETUNREACH
	default:
		return errOpenRungUnclassifiedFailure
	}
}

// openRungFailureStatusError implements the HTTPStatus method connectcore's
// ladder matches broker/CDN statuses on.
type openRungFailureStatusError struct {
	status int
}

func (e *openRungFailureStatusError) Error() string {
	return fmt.Sprintf("platform failure with HTTP status %d", e.status)
}

func (e *openRungFailureStatusError) HTTPStatus() int {
	return e.status
}
