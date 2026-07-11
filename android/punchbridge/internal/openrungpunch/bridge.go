package openrungpunch

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"

	"github.com/sagernet/quic-go"
)

// ClientBridge turns each loopback TCP connection from sing-box into one QUIC
// stream. The volunteer sees the original opaque VLESS/Reality byte stream.
type ClientBridge struct {
	connection *quic.Conn
	token      []byte
	listener   net.Listener
}

func NewClientBridge(connection *quic.Conn, token []byte) (*ClientBridge, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	return &ClientBridge{connection: connection, token: token, listener: listener}, nil
}

func (b *ClientBridge) Endpoint() (host string, port int) {
	address := b.listener.Addr().(*net.TCPAddr)
	return "127.0.0.1", address.Port
}

func (b *ClientBridge) Serve(ctx context.Context) error {
	go func() {
		select {
		case <-ctx.Done():
		case <-b.connection.Context().Done():
		}
		_ = b.listener.Close()
	}()
	for {
		connection, err := b.listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if connectionError := context.Cause(b.connection.Context()); connectionError != nil {
				return connectionError
			}
			return err
		}
		go b.handle(ctx, connection)
	}
}

func (b *ClientBridge) handle(ctx context.Context, connection net.Conn) {
	defer connection.Close()
	stream, err := b.connection.OpenStreamSync(ctx)
	if err != nil {
		// Wake Serve immediately. Otherwise the listener would stay open and
		// sing-box would keep reconnecting to a dead loopback bridge forever.
		_ = b.listener.Close()
		return
	}
	defer stream.Close()
	if _, err := stream.Write(b.token); err != nil {
		return
	}
	streamConnection := &quicStreamConn{
		Stream: stream,
		local:  b.connection.LocalAddr(),
		remote: b.connection.RemoteAddr(),
	}
	pipeConnections(connection, streamConnection)
}

func (b *ClientBridge) Close() error {
	_ = b.listener.Close()
	err := b.connection.CloseWithError(0, "")
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

func pipeConnections(first, second net.Conn) {
	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		_, _ = io.Copy(first, second)
		_ = first.Close()
	}()
	go func() {
		defer wait.Done()
		_, _ = io.Copy(second, first)
		_ = second.Close()
	}()
	wait.Wait()
}
