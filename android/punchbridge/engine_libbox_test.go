//go:build openrung_libbox

package libbox

import (
	"context"
	"errors"
	"os"
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

// A valid TUN config reaches Box.Start, whose failure closes the box itself.
// Keep the invalid-JSON stub strict; this platform supports instance startup.
type engineLibboxStartTestPlatform struct{ engineLibboxTestPlatform }

func (engineLibboxStartTestPlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }
func (engineLibboxStartTestPlatform) UnderNetworkExtension() bool                 { return false }
func (engineLibboxStartTestPlatform) SystemCertificates() StringIterator          { return nil }
func (engineLibboxStartTestPlatform) GetInterfaces() (NetworkInterfaceIterator, error) {
	return nil, nil
}
func (engineLibboxStartTestPlatform) StartDefaultInterfaceMonitor(InterfaceUpdateListener) error {
	return nil
}
func (engineLibboxStartTestPlatform) CloseDefaultInterfaceMonitor(InterfaceUpdateListener) error {
	return nil
}
func (engineLibboxStartTestPlatform) OpenTun(TunOptions) (int32, error) {
	return -1, errors.New("test platform refused TUN")
}

type engineLibboxStartResultService struct {
	openRungEngineService
	result chan error
}

func (s *engineLibboxStartResultService) start(config string) error {
	err := s.openRungEngineService.start(config)
	s.result <- err
	return err
}

func TestOpenRungLibboxFailedInstanceStartCleansUpAndRestarts(t *testing.T) {
	// Supply Setup's filesystem state without redirecting the test process stderr.
	oldWorking, oldTemp, oldUID, oldGID := sWorkingPath, sTempPath, sUserID, sGroupID
	sWorkingPath, sTempPath = t.TempDir(), t.TempDir()
	sUserID, sGroupID = os.Getuid(), os.Getgid()
	t.Cleanup(func() { sWorkingPath, sTempPath, sUserID, sGroupID = oldWorking, oldTemp, oldUID, oldGID })
	runtime := newOpenRungLibboxRuntime(engineLibboxStartTestPlatform{})
	factory := runtime.newService
	result := make(chan error, 1)
	var service *openRungLibboxService
	runtime.newService = func() (openRungEngineService, error) {
		created, err := factory()
		if err != nil {
			return nil, err
		}
		service = created.(*openRungLibboxService)
		return &engineLibboxStartResultService{created, result}, nil
	}
	for range 3 {
		run, err := runtime.Run(context.Background(), []byte(`{"inbounds":[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30"]}]}`))
		if err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-result:
			if err == nil || !strings.Contains(err.Error(), "test platform refused TUN") {
				t.Fatalf("did not reach TUN startup: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("startup did not finish")
		}
		select {
		case err := <-run.Done():
			if err == nil || !strings.Contains(err.Error(), "test platform refused TUN") {
				t.Fatalf("startup error lost: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("startup failure did not reach Done")
		}
		if service.server.Instance() == nil {
			t.Fatal("test never created a libbox instance")
		}
		if err := run.Stop(time.Second); err != nil {
			t.Fatal(err)
		}
		if err := runtime.shutdownError(); err != nil {
			t.Fatal(err)
		}
	}
	// The same runtime must admit and stop a healthy instance after failures.
	run, err := runtime.Run(context.Background(), []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	defer run.Stop(time.Second)
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("restart failed: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("restart did not finish")
	}
	if err := run.Stop(time.Second); err != nil {
		t.Fatal(err)
	}
	if err := runtime.shutdownError(); err != nil {
		t.Fatal(err)
	}
}
