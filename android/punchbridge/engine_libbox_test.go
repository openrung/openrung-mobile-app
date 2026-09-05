//go:build openrung_libbox

package libbox

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Compiled in the real sing-box graft by both release scripts. Embedding the
// platform interface makes an unexpected platform call fail the test; invalid
// config must be rejected before TUN setup or network enumeration.
type engineLibboxTestPlatform struct{ PlatformInterface }

func (engineLibboxTestPlatform) UseProcFS() bool                      { return false }
func (engineLibboxTestPlatform) LocalDNSTransport() LocalDNSTransport { return nil }

func TestOpenRungLibboxLaunchFailureCleansUpAndRestarts(t *testing.T) {
	runtime := newOpenRungLibboxRuntime(engineLibboxTestPlatform{})
	for range 3 {
		run, err := runtime.Run(context.Background(), []byte("invalid libbox JSON"))
		if err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-run.Done():
			if err == nil || !strings.Contains(err.Error(), "decode") {
				t.Fatalf("startup error lost: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("libbox startup failure did not reach Done")
		}
		if err := run.Stop(time.Second); err != nil {
			t.Fatal(err)
		}
	}
}

func TestOpenRungLibboxConstructorsFailClosed(t *testing.T) {
	if engine, err := NewOpenRungEngineForAndroid(`{}`, nil, nil, nil); err == nil || engine != nil {
		t.Fatal("nil Android platform accepted")
	}
	if engine, err := NewOpenRungEngineForAndroid(`{}`, engineLibboxTestPlatform{}, nil, nil); err == nil || engine != nil {
		t.Fatal("invalid hooks returned a non-nil gomobile handle")
	}
	if engine, err := NewOpenRungEngineForIOS(`{}`, engineLibboxTestPlatform{}, nil); err == nil || engine != nil {
		t.Fatal("host test accessed iOS socket exemption")
	}
}
