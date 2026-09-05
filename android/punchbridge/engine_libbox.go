//go:build openrung_libbox

package libbox

import (
	"context"
	"errors"
	"sync"

	"github.com/openrung/openrung/brokerapi"
	"github.com/sagernet/sing-box/daemon"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

// This file is compiled only inside the release scripts' sing-box graft.
// There is one libbox Go runtime; the standalone punchbridge tests inject the
// same service interface without importing a second copy of the libbox package.
func NewOpenRungEngineForAndroid(configJSON string, platform PlatformInterface, protector OpenRungWSSProtector, listener OpenRungEngineListener) (OpenRungEngine, error) {
	if platform == nil {
		return nil, errors.New("libbox platform interface is required")
	}
	engine, err := newOpenRungEngine(configJSON, brokerapi.PlatformAndroid, protector, listener, newOpenRungLibboxRuntime(platform), false)
	if err != nil {
		return nil, err
	}
	return engine, nil
}

func NewOpenRungEngineForIOS(configJSON string, platform PlatformInterface, listener OpenRungEngineListener) (OpenRungEngine, error) {
	if iosConstructorRequiresSocketProtector() {
		return nil, errors.New("iOS engine requires the iOS runtime")
	}
	if platform == nil {
		return nil, errors.New("libbox platform interface is required")
	}
	engine, err := newOpenRungEngine(configJSON, brokerapi.PlatformIOS, nil, listener, newOpenRungLibboxRuntime(platform), true)
	if err != nil {
		return nil, err
	}
	return engine, nil
}

func newOpenRungLibboxRuntime(platform PlatformInterface) *openRungEngineRuntime {
	return &openRungEngineRuntime{newService: func() (openRungEngineService, error) {
		ctx, cancel := context.WithCancel(context.Background())
		s := &openRungLibboxService{ctx: ctx, cancel: cancel, exit: make(chan error, 1), initial: make(chan struct{}), watched: make(chan struct{})}
		server, err := NewCommandServer(s, platform)
		if err != nil {
			cancel()
			return nil, err
		}
		s.server = server
		// Subscribe before launch. Its first Send acknowledges that the
		// subscriber is installed, so a fast startup failure cannot be lost.
		go func() {
			defer close(s.watched)
			err := server.SubscribeServiceStatus(&emptypb.Empty{}, s)
			if ctx.Err() == nil {
				if err == nil {
					err = errors.New("libbox status stream ended")
				}
				s.fail(err)
			}
		}()
		select {
		case <-s.initial:
		case <-s.watched:
			cancel()
			server.Close()
			return nil, errors.New("libbox status subscription failed before launch")
		}
		return s, nil
	}}
}

type openRungLibboxService struct {
	server      *CommandServer
	ctx         context.Context
	cancel      context.CancelFunc
	exit        chan error
	once        sync.Once
	initial     chan struct{}
	initialOnce sync.Once
	watched     chan struct{}
	started     bool // accessed only by the status subscriber
}

func (s *openRungLibboxService) start(configJSON string) error {
	return s.server.StartOrReloadService(configJSON, &OverrideOptions{})
}
func (s *openRungLibboxService) close() error {
	s.cancel()
	<-s.watched
	// CloseService refuses FATAL, even when a failed Start left an instance.
	// Close the instance explicitly in that case as well; CommandServer.Close
	// itself closes observers, not the underlying tunnel.
	var err error
	if instance := s.server.Instance(); instance != nil {
		err = instance.Close()
	}
	s.server.Close()
	return err
}
func (s *openRungLibboxService) done() <-chan error { return s.exit }
func (s *openRungLibboxService) fail(err error)     { s.once.Do(func() { s.exit <- err; close(s.exit) }) }
func (s *openRungLibboxService) Send(status *daemon.ServiceStatus) error {
	s.initialOnce.Do(func() { close(s.initial) })
	switch status.Status {
	case daemon.ServiceStatus_STARTED:
		s.started = true
	case daemon.ServiceStatus_FATAL:
		s.fail(errors.New(status.ErrorMessage))
	case daemon.ServiceStatus_IDLE, daemon.ServiceStatus_STOPPING:
		if s.started {
			s.fail(errors.New("libbox service stopped unexpectedly"))
		}
	}
	return nil
}
func (s *openRungLibboxService) Context() context.Context   { return s.ctx }
func (*openRungLibboxService) SetHeader(metadata.MD) error  { return nil }
func (*openRungLibboxService) SendHeader(metadata.MD) error { return nil }
func (*openRungLibboxService) SetTrailer(metadata.MD)       {}
func (*openRungLibboxService) SendMsg(any) error            { return errors.New("unexpected generic status send") }
func (*openRungLibboxService) RecvMsg(any) error            { return errors.New("status stream is send-only") }

// libbox-initiated stop/reload retires this run. Recovery and reload policy
// belong to connectcore; native code must not start a second orchestrator.
func (s *openRungLibboxService) ServiceStop() error {
	s.fail(errors.New("libbox requested stop"))
	return nil
}
func (s *openRungLibboxService) ServiceReload() error {
	s.fail(errors.New("libbox requested reload"))
	return nil
}
func (*openRungLibboxService) GetSystemProxyStatus() (*SystemProxyStatus, error) {
	return &SystemProxyStatus{}, nil
}
func (*openRungLibboxService) SetSystemProxyEnabled(bool) error {
	return errors.New("mobile engine owns no system proxy")
}
func (*openRungLibboxService) TriggerNativeCrash() error {
	return errors.New("native crash request unavailable")
}
func (*openRungLibboxService) WriteDebugMessage(string) {}
func (*openRungLibboxService) ConnectSSHAgent() (int32, error) {
	return -1, errors.New("SSH agent unavailable")
}
