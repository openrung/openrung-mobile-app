package openrungpunch

import (
	"crypto/subtle"
	"encoding/binary"
	"net"
)

func buildReflectRequest(nonce []byte) []byte {
	packet := make([]byte, reflectMinRequest)
	copy(packet, reflectMagicRequest)
	copy(packet[len(reflectMagicRequest):], nonce)
	return packet
}

func parseReflectReply(data []byte) (nonce []byte, observed *net.UDPAddr, ok bool) {
	offset := len(reflectMagicReply)
	if len(data) < offset+reflectNonceLen+1 || string(data[:offset]) != reflectMagicReply {
		return nil, nil, false
	}
	nonce = make([]byte, reflectNonceLen)
	copy(nonce, data[offset:offset+reflectNonceLen])
	offset += reflectNonceLen

	var addressLength int
	switch data[offset] {
	case 4:
		addressLength = net.IPv4len
	case 6:
		addressLength = net.IPv6len
	default:
		return nil, nil, false
	}
	offset++
	if len(data) < offset+addressLength+2 {
		return nil, nil, false
	}
	ip := make(net.IP, addressLength)
	copy(ip, data[offset:offset+addressLength])
	offset += addressLength
	port := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	return nonce, &net.UDPAddr{IP: ip, Port: port}, true
}

type probeKind int

const (
	probeKindNone probeKind = iota
	probeKindProbe
	probeKindAck
)

func buildProbePacket(magic, sessionID string, token []byte) []byte {
	packet := make([]byte, 0, len(magic)+2+len(sessionID)+len(token))
	packet = append(packet, magic...)
	var sessionLength [2]byte
	binary.BigEndian.PutUint16(sessionLength[:], uint16(len(sessionID)))
	packet = append(packet, sessionLength[:]...)
	packet = append(packet, sessionID...)
	packet = append(packet, token...)
	return packet
}

func parseProbePacket(data []byte, sessionID string, token []byte) probeKind {
	// The probe magic is a prefix of the ACK magic, so check the ACK first.
	if matchProbe(data, probeAckMagic, sessionID, token) {
		return probeKindAck
	}
	if matchProbe(data, probeMagic, sessionID, token) {
		return probeKindProbe
	}
	return probeKindNone
}

func matchProbe(data []byte, magic, sessionID string, token []byte) bool {
	offset := len(magic)
	if len(data) < offset+2 || string(data[:offset]) != magic {
		return false
	}
	sessionLength := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2
	if len(data) < offset+sessionLength+tokenLen || string(data[offset:offset+sessionLength]) != sessionID {
		return false
	}
	offset += sessionLength
	return subtle.ConstantTimeCompare(data[offset:offset+tokenLen], token) == 1
}
