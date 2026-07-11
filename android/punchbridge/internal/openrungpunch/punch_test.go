package openrungpunch

import (
	"bytes"
	"context"
	"net"
	"testing"
	"time"
)

func TestAttemptAuthenticatesBidirectionalPath(t *testing.T) {
	first, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()

	token := bytes.Repeat([]byte{0x7a}, tokenLen)
	deadline := time.Now().Add(2 * time.Second)
	type outcome struct {
		peer *net.UDPAddr
		err  error
	}
	results := make(chan outcome, 2)
	go func() {
		peer, err := Attempt(context.Background(), first, []Endpoint{endpointFromUDP(second.LocalAddr().(*net.UDPAddr), KindHost)}, "session", token, deadline)
		results <- outcome{peer: peer, err: err}
	}()
	go func() {
		peer, err := Attempt(context.Background(), second, []Endpoint{endpointFromUDP(first.LocalAddr().(*net.UDPAddr), KindHost)}, "session", token, deadline)
		results <- outcome{peer: peer, err: err}
	}()
	for count := 0; count < 2; count++ {
		result := <-results
		if result.err != nil || result.peer == nil {
			t.Fatalf("punch failed: peer=%v error=%v", result.peer, result.err)
		}
	}
}
