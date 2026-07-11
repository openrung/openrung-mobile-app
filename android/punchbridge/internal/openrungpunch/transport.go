package openrungpunch

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"net"
	"time"

	"github.com/sagernet/quic-go"
)

func quicConfig() *quic.Config {
	return &quic.Config{
		MaxIdleTimeout:     30 * time.Second,
		KeepAlivePeriod:    15 * time.Second,
		InitialPacketSize:  1200,
		MaxIncomingStreams: 1024,
	}
}

func clientTLSConfig(fingerprint string) *tls.Config {
	return &tls.Config{
		InsecureSkipVerify: true, // Verified by the per-session fingerprint below.
		MinVersion:         tls.VersionTLS13,
		NextProtos:         []string{ALPN},
		VerifyPeerCertificate: func(rawCertificates [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCertificates) == 0 {
				return errors.New("punch peer presented no certificate")
			}
			sum := sha256.Sum256(rawCertificates[0])
			if hex.EncodeToString(sum[:]) != fingerprint {
				return errors.New("punch peer certificate fingerprint mismatch")
			}
			return nil
		},
	}
}

func DialQUIC(
	ctx context.Context,
	socket net.PacketConn,
	peer net.Addr,
	fingerprint string,
) (*quic.Conn, error) {
	return quic.Dial(ctx, socket, peer, clientTLSConfig(fingerprint), quicConfig())
}

type quicStreamConn struct {
	*quic.Stream
	local  net.Addr
	remote net.Addr
}

func (c *quicStreamConn) LocalAddr() net.Addr  { return c.local }
func (c *quicStreamConn) RemoteAddr() net.Addr { return c.remote }
