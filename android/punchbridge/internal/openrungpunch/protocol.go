// Package openrungpunch is the mobile client half of OpenRung's NAT-punch
// protocol. It is kept wire-compatible with internal/punch in the OpenRung
// repository and compiled into the existing libbox gomobile runtime.
package openrungpunch

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strconv"
)

const (
	ALPN         = "openrung-punch/1"
	ProtoVersion = 1

	PathPunchConfig  = "/api/v1/punch/config"
	PathPunchRequest = "/api/v1/punch/request"

	ClassEIM       = "eim"
	ClassSymmetric = "symmetric"
	ClassUnknown   = "unknown"

	KindHost  = "host"
	KindSrflx = "srflx"

	reflectMagicRequest = "ORPUNCHRQ"
	reflectMagicReply   = "ORPUNCHRS"
	reflectNonceLen     = 16
	reflectMinRequest   = 64

	probeMagic    = "ORHOLE"
	probeAckMagic = "ORHOLEACK"
	tokenLen      = sha256.Size
	// Mobile clients never need to spray an unbounded coordinator-provided list.
	// Two reflectors normally produce one or two tuples; four leaves room for
	// symmetric NAT variation while containing a malicious volunteer's target set.
	maxPunchPeers = 4
)

type Endpoint struct {
	IP   string `json:"ip"`
	Port int    `json:"port"`
	Kind string `json:"kind"`
}

func (e Endpoint) UDPAddr() (*net.UDPAddr, error) {
	ip := net.ParseIP(e.IP)
	if ip == nil {
		return nil, fmt.Errorf("invalid endpoint ip %q", e.IP)
	}
	if e.Port < 1 || e.Port > 65535 {
		return nil, fmt.Errorf("invalid endpoint port %d", e.Port)
	}
	return &net.UDPAddr{IP: ip, Port: e.Port}, nil
}

func (e Endpoint) String() string { return net.JoinHostPort(e.IP, strconv.Itoa(e.Port)) }

func endpointFromUDP(addr *net.UDPAddr, kind string) Endpoint {
	return Endpoint{IP: addr.IP.String(), Port: addr.Port, Kind: kind}
}

func dedupeEndpoints(in []Endpoint) []Endpoint {
	seen := make(map[string]struct{}, len(in))
	out := make([]Endpoint, 0, len(in))
	for _, endpoint := range in {
		if endpoint.IP == "" || endpoint.Port <= 0 {
			continue
		}
		key := endpoint.String()
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, endpoint)
	}
	return out
}

func isGloballyRoutable(ip net.IP) bool {
	if ip == nil || ip.IsUnspecified() || ip.IsLoopback() ||
		ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsInterfaceLocalMulticast() {
		return false
	}
	if v4 := ip.To4(); v4 != nil && v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127 {
		return false
	}
	return true
}

// SanitizePeers prevents a coordinator response from turning probe spray into
// an arbitrary UDP reflector and caps work per candidate kind.
func SanitizePeers(in []Endpoint) []Endpoint {
	out := make([]Endpoint, 0, len(in))
	var hostCount, reflexiveCount int
	var reflexiveIP net.IP
	for _, endpoint := range dedupeEndpoints(in) {
		ip := net.ParseIP(endpoint.IP)
		if ip == nil || endpoint.Port < 1 || endpoint.Port > 65535 || ip.IsMulticast() || ip.IsUnspecified() {
			continue
		}
		switch endpoint.Kind {
		case KindHost:
			if isGloballyRoutable(ip) || hostCount >= maxPunchPeers {
				continue
			}
			hostCount++
		case KindSrflx:
			// A reflector-observed tuple is public in production. Reject private
			// values so an unauthenticated coordinator cannot relabel a LAN target
			// and turn the mobile client into a local-network UDP probe source.
			if !isGloballyRoutable(ip) || reflexiveCount >= maxPunchPeers {
				continue
			}
			// Reflectors may observe different ports for a symmetric NAT, but a
			// volunteer session is expected to have one public egress address. Do
			// not let it fan a client's authenticated probes out across public IPs.
			if reflexiveIP == nil {
				reflexiveIP = append(net.IP(nil), ip...)
			} else if !reflexiveIP.Equal(ip) {
				continue
			}
			reflexiveCount++
		default:
			continue
		}
		out = append(out, endpoint)
	}
	return out
}

type PunchConfig struct {
	ReflectorAddrs []string `json:"reflector_addrs"`
	ALPN           string   `json:"quic_alpn"`
	TTLMillis      int64    `json:"ttl_ms"`
}

type PunchRequest struct {
	RelayID         string     `json:"relay_id"`
	ClientNonce     string     `json:"client_nonce"`
	ClientReflexive []Endpoint `json:"client_reflexive,omitempty"`
	ClientLocal     []Endpoint `json:"client_local,omitempty"`
	ClientClass     string     `json:"client_class,omitempty"`
	QUICALPN        string     `json:"quic_alpn"`
	ProtoVersion    int        `json:"proto_version"`
}

type PunchResponse struct {
	OK                 bool       `json:"ok"`
	Error              string     `json:"error,omitempty"`
	SessionID          string     `json:"session_id,omitempty"`
	VolunteerReflexive []Endpoint `json:"volunteer_reflexive,omitempty"`
	VolunteerLocal     []Endpoint `json:"volunteer_local,omitempty"`
	VolunteerClass     string     `json:"volunteer_class,omitempty"`
	PunchToken         string     `json:"punch_token,omitempty"`
	CertFingerprint    string     `json:"cert_fingerprint,omitempty"`
	TTLMillis          int64      `json:"ttl_ms,omitempty"`
}

type PunchResult struct {
	SessionID string
	OK        bool
	Reason    string
	RTTMillis int64
	NATClass  string
}

func DecodeToken(value string) ([]byte, error) {
	raw, err := hex.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("decode punch token: %w", err)
	}
	if len(raw) != tokenLen {
		return nil, errors.New("punch token has wrong length")
	}
	return raw, nil
}
