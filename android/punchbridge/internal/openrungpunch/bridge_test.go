package openrungpunch

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"fmt"
	"io"
	"math/big"
	"net"
	"testing"
	"time"

	"github.com/sagernet/quic-go"
)

func TestClientBridgeCarriesOpaqueBytesOverQUIC(t *testing.T) {
	certificate, fingerprint := testCertificate(t)
	serverSocket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener, err := quic.Listen(serverSocket, &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{ALPN},
	}, quicConfig())
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	token := make([]byte, tokenLen)
	_, _ = rand.Read(token)
	serverError := make(chan error, 1)
	go func() {
		connection, err := listener.Accept(ctx)
		if err != nil {
			serverError <- err
			return
		}
		defer connection.CloseWithError(0, "")
		stream, err := connection.AcceptStream(ctx)
		if err != nil {
			serverError <- err
			return
		}
		header := make([]byte, tokenLen)
		if _, err := io.ReadFull(stream, header); err != nil {
			serverError <- err
			return
		}
		if string(header) != string(token) {
			serverError <- io.ErrUnexpectedEOF
			return
		}
		payload := make([]byte, 18)
		if _, err := io.ReadFull(stream, payload); err != nil {
			serverError <- err
			return
		}
		_, err = stream.Write(payload)
		_ = stream.Close()
		// Let quic-go flush the stream FIN and payload before the test closes the
		// whole connection; an immediate application close may discard in-flight data.
		time.Sleep(50 * time.Millisecond)
		serverError <- err
	}()

	clientSocket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	connection, err := DialQUIC(ctx, clientSocket, serverSocket.LocalAddr(), fingerprint)
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := NewClientBridge(connection, token)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Close()
	serveDone := make(chan error, 1)
	go func() { serveDone <- bridge.Serve(ctx) }()

	host, port := bridge.Endpoint()
	tcp, err := net.DialTimeout("tcp", net.JoinHostPort(host, fmt.Sprint(port)), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	_ = tcp.SetDeadline(time.Now().Add(2 * time.Second))
	payload := []byte("hello-punched-path")
	if _, err := tcp.Write(payload); err != nil {
		t.Fatal(err)
	}
	echo := make([]byte, len(payload))
	if _, err := io.ReadFull(tcp, echo); err != nil {
		t.Fatal(err)
	}
	if string(echo) != string(payload) {
		t.Fatalf("echo = %q", echo)
	}
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-serveDone:
		if err == nil {
			t.Fatal("remote QUIC close should be surfaced as a bridge failure")
		}
	case <-time.After(time.Second):
		t.Fatal("bridge did not surface the remote QUIC close")
	}
}

func testCertificate(t *testing.T) (tls.Certificate, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "openrung-punch-test"},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, hex.EncodeToString(sum[:])
}
