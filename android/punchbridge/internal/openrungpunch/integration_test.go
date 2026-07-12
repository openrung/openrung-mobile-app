package openrungpunch

import (
	"bytes"
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openrung/openrung/punchcore"
	upstreamquic "github.com/quic-go/quic-go"
)

// Private copies of the reflector wire framing. This is a cross-fork
// wire-compatibility test, so the literal bytes are a feature: the test must
// keep speaking the frozen wire format independently of the punchcore module
// it exercises.
const (
	integrationReflectMagicRequest = "ORPUNCHRQ"
	integrationReflectMagicReply   = "ORPUNCHRS"
	integrationReflectNonceLen     = 16
	integrationReflectMinRequest   = 64
)

// TestAndroidPunchFlowEndToEnd exercises Dialer.Establish in the same order as
// the Android binding: socket protection, coordinator config, reflector
// discovery, rendezvous request, authenticated simultaneous UDP punch,
// certificate-pinned QUIC, and the loopback TCP bridge consumed by sing-box.
//
// Production deliberately accepts only public reflector and server-reflexive
// tuples. A hermetic test cannot own a public address, so the Dialer's two
// unexported candidate-policy seams substitute loopback host tuples here. The
// client remains the Android github.com/sagernet/quic-go fork while the test
// volunteer uses the desktop's upstream github.com/quic-go/quic-go, exercising
// their wire compatibility rather than linking both ends to the same stack.
func TestAndroidPunchFlowEndToEnd(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	targetAddress := startIntegrationEchoServer(t)
	reflector := listenIntegrationUDP(t)
	volunteer := listenIntegrationUDP(t)

	const (
		relayID   = "relay-android-integration"
		sessionID = "session-android-integration"
	)
	token := bytes.Repeat([]byte{0x6d}, punchcore.TokenLen)
	certificate, certificateFingerprint := testCertificate(t)

	reflectionDone := make(chan integrationReflection, 1)
	go serveOneIntegrationReflection(ctx, reflector, reflectionDone)

	requestSeen := make(chan punchcore.PunchRequest, 1)
	volunteerReady := make(chan struct{})
	volunteerDone := make(chan error, 1)
	var startVolunteer sync.Once
	var configCalls atomic.Int32
	var requestCalls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch {
		case request.Method == http.MethodGet && request.URL.Path == punchcore.PathPunchConfig:
			configCalls.Add(1)
			_ = json.NewEncoder(writer).Encode(punchcore.PunchConfig{
				ReflectorAddrs: []string{reflector.LocalAddr().String()},
				ALPN:           punchcore.ALPN,
				TTLMillis:      3_000,
			})
		case request.Method == http.MethodPost && request.URL.Path == punchcore.PathPunchRequest:
			requestCalls.Add(1)
			var punchRequest punchcore.PunchRequest
			if err := json.NewDecoder(request.Body).Decode(&punchRequest); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			select {
			case requestSeen <- punchRequest:
			default:
			}
			if len(punchRequest.ClientReflexive) != 1 {
				http.Error(writer, "expected one client candidate", http.StatusBadRequest)
				return
			}
			clientAddress, err := punchRequest.ClientReflexive[0].UDPAddr()
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			startVolunteer.Do(func() {
				go runIntegrationVolunteer(
					ctx,
					volunteer,
					clientAddress,
					sessionID,
					token,
					certificate,
					targetAddress,
					volunteerReady,
					volunteerDone,
				)
			})
			volunteerAddress := volunteer.LocalAddr().(*net.UDPAddr)
			_ = json.NewEncoder(writer).Encode(punchcore.PunchResponse{
				OK:        true,
				SessionID: sessionID,
				// Loopback is advertised as a host candidate only for this
				// hermetic test. Production coordinators provide a public srflx.
				VolunteerLocal: []punchcore.Endpoint{{
					IP:   volunteerAddress.IP.String(),
					Port: volunteerAddress.Port,
					Kind: punchcore.KindHost,
				}},
				VolunteerClass:  punchcore.ClassEIM,
				PunchToken:      hex.EncodeToString(token),
				CertFingerprint: certificateFingerprint,
				TTLMillis:       3_000,
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(coordinator.Close)

	var protectedCalls atomic.Int32
	var protectedFD atomic.Int64
	dialer := Dialer{
		Hub:     punchcore.HubClient{BaseURL: coordinator.URL, HTTPClient: punchcore.HardenedHTTPClient()},
		RelayID: relayID,
		ProtectSocket: func(fd int64) bool {
			protectedCalls.Add(1)
			protectedFD.Store(fd)
			return fd >= 0
		},
		gatherCandidates: func(
			ctx context.Context,
			socket *net.UDPConn,
			reflectorAddresses []string,
			nonce []byte,
		) ([]punchcore.Endpoint, string, error) {
			if len(reflectorAddresses) != 1 {
				return nil, punchcore.ClassUnknown, fmt.Errorf("reflectors = %v, want one", reflectorAddresses)
			}
			candidate, err := gatherIntegrationLoopback(ctx, socket, reflectorAddresses[0], nonce)
			if err != nil {
				return nil, punchcore.ClassUnknown, err
			}
			return []punchcore.Endpoint{candidate}, punchcore.ClassUnknown, nil
		},
		selectPeerCandidates: func(response punchcore.PunchResponse) []punchcore.Endpoint {
			return response.VolunteerLocal
		},
	}

	establishment, result, err := dialer.Establish(ctx)
	if err != nil {
		t.Fatalf("Dialer.Establish: %v (result=%+v)", err, result)
	}
	t.Cleanup(func() { _ = establishment.Close() })
	if !result.OK || result.SessionID != sessionID || establishment.SessionID != sessionID {
		t.Fatalf("unexpected establishment/result: establishment=%+v result=%+v", establishment, result)
	}
	if establishment.PeerIP != volunteer.LocalAddr().(*net.UDPAddr).IP.String() {
		t.Fatalf("peer IP = %q, want %q", establishment.PeerIP, volunteer.LocalAddr().(*net.UDPAddr).IP)
	}
	if protectedCalls.Load() != 1 || protectedFD.Load() < 0 {
		t.Fatalf("socket protection calls=%d fd=%d", protectedCalls.Load(), protectedFD.Load())
	}

	bridgeDone := make(chan error, 1)
	go func() { bridgeDone <- establishment.Bridge.Serve(ctx) }()
	payload := []byte("opaque-vless-reality-over-android-punch")
	bridgeAddress := net.JoinHostPort(establishment.BridgeHost, strconv.Itoa(establishment.BridgePort))
	if err := integrationEchoRoundTrip(ctx, bridgeAddress, payload); err != nil {
		t.Fatalf("echo through loopback TCP -> cross-fork QUIC -> volunteer: %v", err)
	}

	clientUDPPort := establishment.Bridge.connection.LocalAddr().(*net.UDPAddr).Port
	var observedNonce []byte
	select {
	case observation := <-reflectionDone:
		if observation.err != nil {
			t.Fatalf("reflector: %v", observation.err)
		}
		if observation.source.Port != clientUDPPort {
			t.Fatalf("reflection used UDP port %d, QUIC used %v", observation.source.Port, establishment.Bridge.connection.LocalAddr())
		}
		observedNonce = observation.nonce
	case <-ctx.Done():
		t.Fatal("timed out waiting for reflector observation")
	}

	select {
	case punchRequest := <-requestSeen:
		if punchRequest.RelayID != relayID || punchRequest.ClientNonce != hex.EncodeToString(observedNonce) ||
			punchRequest.QUICALPN != punchcore.ALPN || punchRequest.ProtoVersion != punchcore.ProtoVersion {
			t.Fatalf("unexpected coordinator request: %+v", punchRequest)
		}
		if len(punchRequest.ClientReflexive) != 1 || punchRequest.ClientReflexive[0].Port != clientUDPPort {
			t.Fatalf("coordinator did not receive the retained client tuple: %+v", punchRequest.ClientReflexive)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for coordinator request")
	}

	if configCalls.Load() != 1 || requestCalls.Load() != 1 {
		t.Fatalf("coordinator calls: config=%d request=%d", configCalls.Load(), requestCalls.Load())
	}
	select {
	case <-volunteerReady:
	default:
		t.Fatal("upstream quic-go volunteer never reached its listener")
	}

	if err := establishment.Close(); err != nil {
		t.Fatalf("close establishment: %v", err)
	}
	select {
	case err := <-volunteerDone:
		if err != nil && !errors.Is(err, context.Canceled) {
			t.Fatalf("volunteer bridge: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("volunteer did not finish after client bridge closed")
	}
	select {
	case <-bridgeDone:
	case <-time.After(2 * time.Second):
		t.Fatal("client bridge did not stop after Close")
	}
}

type integrationReflection struct {
	nonce  []byte
	source *net.UDPAddr
	err    error
}

func listenIntegrationUDP(t *testing.T) *net.UDPConn {
	t.Helper()
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen UDP: %v", err)
	}
	t.Cleanup(func() { _ = socket.Close() })
	return socket
}

func serveOneIntegrationReflection(ctx context.Context, reflector *net.UDPConn, done chan<- integrationReflection) {
	buffer := make([]byte, 1500)
	_ = reflector.SetReadDeadline(deadlineFromContext(ctx, 3*time.Second))
	count, source, err := reflector.ReadFromUDP(buffer)
	if err != nil {
		done <- integrationReflection{err: err}
		return
	}
	request := buffer[:count]
	if len(request) < integrationReflectMinRequest || !bytes.HasPrefix(request, []byte(integrationReflectMagicRequest)) {
		done <- integrationReflection{err: errors.New("invalid reflector request")}
		return
	}
	nonceOffset := len(integrationReflectMagicRequest)
	nonce := append([]byte(nil), request[nonceOffset:nonceOffset+integrationReflectNonceLen]...)
	reply := integrationReflectReply(nonce, source)
	if _, err := reflector.WriteToUDP(reply, source); err != nil {
		done <- integrationReflection{err: err}
		return
	}
	done <- integrationReflection{nonce: nonce, source: source}
}

func gatherIntegrationLoopback(ctx context.Context, socket *net.UDPConn, reflectorAddress string, nonce []byte) (punchcore.Endpoint, error) {
	reflector, err := net.ResolveUDPAddr("udp4", reflectorAddress)
	if err != nil {
		return punchcore.Endpoint{}, err
	}
	if _, err := socket.WriteToUDP(integrationReflectRequest(nonce), reflector); err != nil {
		return punchcore.Endpoint{}, err
	}
	_ = socket.SetReadDeadline(deadlineFromContext(ctx, 3*time.Second))
	buffer := make([]byte, 1500)
	count, source, err := socket.ReadFromUDP(buffer)
	_ = socket.SetReadDeadline(time.Time{})
	if err != nil {
		return punchcore.Endpoint{}, err
	}
	if !source.IP.Equal(reflector.IP) || source.Port != reflector.Port {
		return punchcore.Endpoint{}, fmt.Errorf("reflection reply source = %v, want %v", source, reflector)
	}
	replyNonce, observed, valid := integrationParseReflectReply(buffer[:count])
	if !valid || !bytes.Equal(replyNonce, nonce) {
		return punchcore.Endpoint{}, errors.New("invalid reflection response")
	}
	return punchcore.Endpoint{IP: observed.IP.String(), Port: observed.Port, Kind: punchcore.KindHost}, nil
}

// integrationReflectRequest builds a reflector request frame: magic + nonce,
// zero-padded to the anti-amplification floor.
func integrationReflectRequest(nonce []byte) []byte {
	request := make([]byte, integrationReflectMinRequest)
	copy(request, integrationReflectMagicRequest)
	copy(request[len(integrationReflectMagicRequest):], nonce)
	return request
}

func integrationReflectReply(nonce []byte, observed *net.UDPAddr) []byte {
	ip := observed.IP.To4()
	reply := make([]byte, 0, len(integrationReflectMagicReply)+integrationReflectNonceLen+1+net.IPv4len+2)
	reply = append(reply, integrationReflectMagicReply...)
	reply = append(reply, nonce...)
	reply = append(reply, byte(net.IPv4len))
	reply = append(reply, ip...)
	var port [2]byte
	binary.BigEndian.PutUint16(port[:], uint16(observed.Port))
	reply = append(reply, port[:]...)
	return reply
}

// integrationParseReflectReply parses a reflector reply frame: magic + echoed
// nonce + one address-family byte (4 or 6) + IP + big-endian port.
func integrationParseReflectReply(data []byte) (nonce []byte, observed *net.UDPAddr, ok bool) {
	offset := len(integrationReflectMagicReply)
	if len(data) < offset+integrationReflectNonceLen+1 {
		return nil, nil, false
	}
	if string(data[:offset]) != integrationReflectMagicReply {
		return nil, nil, false
	}
	nonce = append([]byte(nil), data[offset:offset+integrationReflectNonceLen]...)
	offset += integrationReflectNonceLen
	var ipLen int
	switch data[offset] {
	case 4:
		ipLen = net.IPv4len
	case 6:
		ipLen = net.IPv6len
	default:
		return nil, nil, false
	}
	offset++
	if len(data) < offset+ipLen+2 {
		return nil, nil, false
	}
	ip := make(net.IP, ipLen)
	copy(ip, data[offset:offset+ipLen])
	offset += ipLen
	port := binary.BigEndian.Uint16(data[offset : offset+2])
	return nonce, &net.UDPAddr{IP: ip, Port: int(port)}, true
}

func runIntegrationVolunteer(
	ctx context.Context,
	socket *net.UDPConn,
	clientAddress *net.UDPAddr,
	sessionID string,
	token []byte,
	certificate tls.Certificate,
	targetAddress string,
	ready chan<- struct{},
	done chan<- error,
) {
	confirmed, err := punchcore.MobilePolicy().Attempt(
		ctx,
		socket,
		[]punchcore.Endpoint{{
			IP:   clientAddress.IP.String(),
			Port: clientAddress.Port,
			Kind: punchcore.KindHost,
		}},
		sessionID,
		token,
		time.Now().Add(3*time.Second),
	)
	if err != nil {
		done <- fmt.Errorf("volunteer UDP punch: %w", err)
		return
	}
	if confirmed.Port != clientAddress.Port {
		done <- fmt.Errorf("volunteer confirmed %v, want %v", confirmed, clientAddress)
		return
	}
	listener, err := upstreamquic.Listen(socket, &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{punchcore.ALPN},
	}, integrationUpstreamQUICConfig())
	if err != nil {
		done <- err
		return
	}
	defer listener.Close()
	close(ready)

	connection, err := listener.Accept(ctx)
	if err != nil {
		done <- err
		return
	}
	defer connection.CloseWithError(0, "")
	stream, err := connection.AcceptStream(ctx)
	if err != nil {
		done <- err
		return
	}
	defer stream.Close()

	streamToken := make([]byte, punchcore.TokenLen)
	_ = stream.SetReadDeadline(deadlineFromContext(ctx, 3*time.Second))
	if _, err := io.ReadFull(stream, streamToken); err != nil {
		done <- err
		return
	}
	if subtle.ConstantTimeCompare(streamToken, token) != 1 {
		done <- errors.New("volunteer rejected unauthenticated stream")
		return
	}
	_ = stream.SetReadDeadline(time.Time{})

	target, err := (&net.Dialer{}).DialContext(ctx, "tcp", targetAddress)
	if err != nil {
		done <- err
		return
	}
	defer target.Close()
	streamConnection := &integrationUpstreamStreamConn{
		Stream: stream,
		local:  connection.LocalAddr(),
		remote: connection.RemoteAddr(),
	}
	pipeConnections(streamConnection, target)
	done <- nil
}

func integrationUpstreamQUICConfig() *upstreamquic.Config {
	return &upstreamquic.Config{
		MaxIdleTimeout:     30 * time.Second,
		KeepAlivePeriod:    15 * time.Second,
		InitialPacketSize:  1200,
		MaxIncomingStreams: 1024,
	}
}

type integrationUpstreamStreamConn struct {
	*upstreamquic.Stream
	local  net.Addr
	remote net.Addr
}

func (c *integrationUpstreamStreamConn) LocalAddr() net.Addr  { return c.local }
func (c *integrationUpstreamStreamConn) RemoteAddr() net.Addr { return c.remote }

func startIntegrationEchoServer(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen echo server: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				_, _ = io.Copy(connection, connection)
			}()
		}
	}()
	return listener.Addr().String()
}

func integrationEchoRoundTrip(ctx context.Context, address string, payload []byte) error {
	connection, err := (&net.Dialer{}).DialContext(ctx, "tcp", address)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(deadlineFromContext(ctx, 3*time.Second))
	if _, err := connection.Write(payload); err != nil {
		return err
	}
	echo := make([]byte, len(payload))
	if _, err := io.ReadFull(connection, echo); err != nil {
		return err
	}
	if !bytes.Equal(echo, payload) {
		return fmt.Errorf("echo = %q, want %q", echo, payload)
	}
	return nil
}

func deadlineFromContext(ctx context.Context, fallback time.Duration) time.Time {
	deadline := time.Now().Add(fallback)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		return contextDeadline
	}
	return deadline
}
