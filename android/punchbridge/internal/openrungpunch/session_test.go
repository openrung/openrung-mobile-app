package openrungpunch

import (
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func TestDialerSocketProtectionPolicy(t *testing.T) {
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()

	t.Run("Android nil fails closed", func(t *testing.T) {
		err := (&Dialer{}).protectSocket(socket)
		if err == nil || !strings.Contains(err.Error(), "required") {
			t.Fatalf("nil Android protector error = %v", err)
		}
	})

	t.Run("iOS explicitly allows nil", func(t *testing.T) {
		err := (&Dialer{AllowUnprotectedSocket: true}).protectSocket(socket)
		if err != nil {
			t.Fatalf("iOS nil-protector path failed: %v", err)
		}
	})

	t.Run("Android rejection fails closed", func(t *testing.T) {
		var calls atomic.Int32
		err := (&Dialer{ProtectSocket: func(fd int64) bool {
			calls.Add(1)
			return fd < 0
		}}).protectSocket(socket)
		if err == nil || !strings.Contains(err.Error(), "rejected") {
			t.Fatalf("rejecting protector error = %v", err)
		}
		if calls.Load() != 1 {
			t.Fatalf("protector calls = %d, want 1", calls.Load())
		}
	})

	t.Run("Android panic fails closed", func(t *testing.T) {
		err := (&Dialer{ProtectSocket: func(int64) bool {
			panic("broken gomobile proxy")
		}}).protectSocket(socket)
		if err == nil || !strings.Contains(err.Error(), "panicked") {
			t.Fatalf("panicking protector error = %v", err)
		}
	})
}

func TestEstablishmentCloseIsConcurrentAndIdempotent(t *testing.T) {
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	establishment := &Establishment{socket: socket}

	const callers = 8
	var wait sync.WaitGroup
	wait.Add(callers)
	errors := make(chan error, callers)
	for range callers {
		go func() {
			defer wait.Done()
			errors <- establishment.Close()
		}()
	}
	wait.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatalf("concurrent Close failed: %v", err)
		}
	}
}
