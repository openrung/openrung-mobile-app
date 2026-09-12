package libbox

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/openrung/openrung/connectcore"
)

// The service factory is Go-only. engine_libbox.go supplies libbox's concrete
// service in the graft; tests exercise exactly this runtime with a fake service.
type openRungEngineService interface {
	start(configJSON string) error
	close() error
	done() <-chan error
}
type openRungEngineRuntime struct {
	mu         sync.Mutex
	paused     bool
	active     *openRungEngineRun
	newService func() (openRungEngineService, error)
}

func (r *openRungEngineRuntime) Run(ctx context.Context, configJSON []byte) (connectcore.TunnelRun, error) {
	return r.runWithService(ctx, configJSON, r.newService)
}

func (r *openRungEngineRuntime) runWithService(ctx context.Context, configJSON []byte, factory func() (openRungEngineService, error)) (connectcore.TunnelRun, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if r.active != nil {
		return nil, errors.New("previous libbox service has not finished teardown")
	}
	service, err := factory()
	if err != nil {
		return nil, err
	}
	if pausable, ok := service.(interface{ setPaused(bool) }); ok {
		pausable.setPaused(r.paused)
	}
	run := &openRungEngineRun{service: service, doneCh: make(chan error, 1), stopped: make(chan struct{}), stop: make(chan struct{})}
	r.active = run
	// Return at launched, not at ready. In-process Start can block on native
	// TUN setup; the engine's readiness probe still owns readiness. A cancelled
	// launch is cleaned up before this runtime will admit another run.
	configuration := string(configJSON)
	go func() {
		err := ctx.Err()
		if err == nil {
			select {
			case <-run.stop:
				err = context.Canceled
			default:
				err = service.start(configuration)
			}
		}
		if err == nil {
			select {
			case err = <-service.done():
				if err == nil {
					err = errors.New("libbox service exited unexpectedly")
				}
			case <-run.stop:
			case <-ctx.Done():
			}
		}
		closeErr := service.close()
		if closeErr != nil {
			err = fmt.Errorf("libbox teardown: %w", closeErr)
		}
		run.mu.Lock()
		run.stopErr = closeErr
		requested := run.requested
		run.mu.Unlock()
		if requested && closeErr == nil {
			err = nil
		}
		r.mu.Lock()
		// A failed close poisons the runtime: never overlap a possibly live
		// TUN with a fresh service. Recovery requires a new platform process.
		if closeErr == nil {
			r.active = nil
		}
		r.mu.Unlock()
		run.doneCh <- err
		close(run.doneCh)
		close(run.stopped)
	}()
	return run, nil
}

func (r *openRungEngineRuntime) shutdownError() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active != nil {
		r.active.mu.Lock()
		closeErr := r.active.stopErr
		r.active.mu.Unlock()
		return errors.Join(errors.New("libbox teardown is incomplete; the platform must retain its TUN owner"), closeErr)
	}
	return nil
}

type openRungEngineRun struct {
	service   openRungEngineService
	mu        sync.Mutex
	requested bool
	stopErr   error
	stopOnce  sync.Once
	stop      chan struct{}
	doneCh    chan error
	stopped   chan struct{}
}

func (r *openRungEngineRun) Done() <-chan error { return r.doneCh }
func (r *openRungEngineRun) Stop(grace time.Duration) error {
	r.stopOnce.Do(func() { r.mu.Lock(); r.requested = true; r.mu.Unlock(); close(r.stop) })
	if grace <= 0 {
		grace = 5 * time.Second
	}
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-r.stopped:
		r.mu.Lock()
		defer r.mu.Unlock()
		return r.stopErr
	case <-timer.C:
		// Go cannot safely kill an in-process goroutine. Retain the active
		// handle until cleanup really completes, and report the missed budget.
		return errors.New("libbox teardown exceeded its deadline")
	}
}

func (r *openRungEngineRuntime) setPaused(paused bool) {
	r.mu.Lock()
	r.paused = paused
	active := r.active
	r.mu.Unlock()
	if active != nil {
		if service, ok := active.service.(interface{ setPaused(bool) }); ok {
			service.setPaused(paused)
		}
	}
}
