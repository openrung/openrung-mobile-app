// Package openrungpunch is the sagernet-QUIC session, transport and bridge
// layer of the OpenRung mobile NAT-punch client, over the shared protocol core
// github.com/openrung/openrung/punchcore.
package openrungpunch

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/openrung/openrung/punchcore"
)

const (
	maxPunchTTL          = 15 * time.Second
	maxReflectorCount    = 4
	quicHandshakeTimeout = 5 * time.Second
)

// mobilePolicy is the hardened punchcore candidate/gather profile the Android
// client always runs in production.
var mobilePolicy = punchcore.MobilePolicy()

type Dialer struct {
	Hub           punchcore.HubClient
	RelayID       string
	ProtectSocket func(fd int64) bool

	// Nil selects the hardened production candidate policy. These unexported
	// seams let hermetic package tests substitute loopback tuples without
	// weakening the public-address checks used by Android builds.
	gatherCandidates     func(context.Context, *net.UDPConn, []string, []byte) ([]punchcore.Endpoint, string, error)
	selectPeerCandidates func(punchcore.PunchResponse) []punchcore.Endpoint
}

type Establishment struct {
	Bridge     *ClientBridge
	BridgeHost string
	BridgePort int
	PeerIP     string
	SessionID  string
	NATClass   string

	socket *net.UDPConn
}

func (e *Establishment) Close() error {
	if e == nil {
		return nil
	}
	if e.Bridge != nil {
		_ = e.Bridge.Close()
	}
	if e.socket != nil {
		_ = e.socket.Close()
	}
	return nil
}

func socketFD(socket *net.UDPConn) (int64, error) {
	raw, err := socket.SyscallConn()
	if err != nil {
		return -1, fmt.Errorf("access punch socket: %w", err)
	}
	var descriptor int64 = -1
	if err := raw.Control(func(fd uintptr) {
		descriptor = int64(fd)
	}); err != nil {
		return -1, fmt.Errorf("read punch socket descriptor: %w", err)
	}
	if descriptor < 0 {
		return -1, errors.New("punch socket descriptor is invalid")
	}
	return descriptor, nil
}

// Establish runs the shared punchcore client flow. The one UDP socket is
// retained from reflector discovery through the lifetime of QUIC.
func (d *Dialer) Establish(ctx context.Context) (*Establishment, punchcore.PunchResult, error) {
	started := time.Now()
	result := punchcore.PunchResult{}

	config, err := d.Hub.FetchConfig(ctx)
	if err != nil {
		result.Reason = "config"
		return nil, result, err
	}
	if config.ALPN != "" && config.ALPN != punchcore.ALPN {
		result.Reason = "config"
		return nil, result, fmt.Errorf("unsupported punch ALPN %q", config.ALPN)
	}

	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		result.Reason = "socket"
		return nil, result, err
	}
	established := false
	defer func() {
		if !established {
			_ = socket.Close()
		}
	}()

	fd, err := socketFD(socket)
	if err != nil {
		result.Reason = "protect"
		return nil, result, err
	}
	if d.ProtectSocket == nil || !d.ProtectSocket(fd) {
		result.Reason = "protect"
		return nil, result, errors.New("VpnService rejected punch socket protection")
	}

	nonceHex, nonceRaw, err := punchcore.GenerateNonce()
	if err != nil {
		result.Reason = "nonce"
		return nil, result, err
	}
	reflectors := config.ReflectorAddrs
	if len(reflectors) > maxReflectorCount {
		reflectors = reflectors[:maxReflectorCount]
	}
	gatherCandidates := mobilePolicy.Gather
	if d.gatherCandidates != nil {
		gatherCandidates = d.gatherCandidates
	}
	reflexive, natClass, gatherError := gatherCandidates(ctx, socket, reflectors, nonceRaw)
	result.NATClass = natClass
	if len(reflexive) == 0 {
		result.Reason = "discovery"
		if gatherError == nil {
			gatherError = errors.New("no candidates gathered")
		}
		return nil, result, gatherError
	}

	response, err := d.Hub.RequestPunch(ctx, punchcore.PunchRequest{
		RelayID:         d.RelayID,
		ClientNonce:     nonceHex,
		ClientReflexive: reflexive,
		ClientClass:     natClass,
		QUICALPN:        punchcore.ALPN,
		ProtoVersion:    punchcore.ProtoVersion,
	})
	if err != nil {
		result.Reason = "request"
		return nil, result, err
	}
	result.SessionID = response.SessionID
	if !response.OK {
		result.Reason = "declined:" + response.Error
		return nil, result, fmt.Errorf("hub declined punch: %s", response.Error)
	}
	if len(response.SessionID) == 0 || len(response.SessionID) > 128 {
		result.Reason = "session"
		return nil, result, errors.New("hub returned an invalid punch session id")
	}

	token, err := punchcore.DecodeToken(response.PunchToken)
	if err != nil {
		result.Reason = "token"
		return nil, result, err
	}
	if fingerprint, decodeErr := hex.DecodeString(response.CertFingerprint); decodeErr != nil || len(fingerprint) != punchcore.TokenLen {
		result.Reason = "certificate"
		return nil, result, errors.New("hub returned an invalid punch certificate fingerprint")
	}
	ttl := time.Duration(response.TTLMillis) * time.Millisecond
	if ttl <= 0 {
		ttl = punchcore.DefaultTTL
	} else if ttl > maxPunchTTL {
		ttl = maxPunchTTL
	}
	// Only reflector-observed public tuples are actionable on mobile. Accepting
	// coordinator-provided RFC1918 host candidates would let a malicious volunteer
	// direct probes at another device on the phone's LAN. Same-LAN peers can still
	// meet through their public tuple when hairpinning works and otherwise retain
	// the normal RelayHub fallback.
	peers := append([]punchcore.Endpoint{}, response.VolunteerReflexive...)
	if d.selectPeerCandidates != nil {
		peers = append([]punchcore.Endpoint{}, d.selectPeerCandidates(response)...)
	}
	confirmed, err := mobilePolicy.Attempt(ctx, socket, peers, response.SessionID, token, time.Now().Add(ttl))
	if err != nil {
		result.Reason = "punch"
		return nil, result, err
	}
	dialContext, cancel := context.WithTimeout(ctx, quicHandshakeTimeout)
	defer cancel()
	connection, err := DialQUIC(dialContext, socket, confirmed, response.CertFingerprint)
	if err != nil {
		result.Reason = "quic"
		return nil, result, err
	}
	bridge, err := NewClientBridge(connection, token)
	if err != nil {
		_ = connection.CloseWithError(0, "")
		result.Reason = "bridge"
		return nil, result, err
	}

	host, port := bridge.Endpoint()
	established = true
	result.OK = true
	result.RTTMillis = time.Since(started).Milliseconds()
	return &Establishment{
		Bridge:     bridge,
		BridgeHost: host,
		BridgePort: port,
		PeerIP:     confirmed.IP.String(),
		SessionID:  response.SessionID,
		NATClass:   response.VolunteerClass,
		socket:     socket,
	}, result, nil
}
