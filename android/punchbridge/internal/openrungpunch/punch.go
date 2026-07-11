package openrungpunch

import (
	"context"
	"errors"
	"net"
	"time"
)

const probeInterval = 50 * time.Millisecond

var ErrPunchTimeout = errors.New("nat hole punch timed out")

// Attempt performs authenticated simultaneous-open probing. It leaves socket
// unconnected with no reader goroutine so the QUIC stack can adopt it safely.
func Attempt(
	ctx context.Context,
	socket *net.UDPConn,
	peers []Endpoint,
	sessionID string,
	token []byte,
	deadline time.Time,
) (*net.UDPAddr, error) {
	peerAddresses := make([]*net.UDPAddr, 0, len(peers))
	for _, peer := range SanitizePeers(peers) {
		if address, err := peer.UDPAddr(); err == nil {
			peerAddresses = append(peerAddresses, address)
		}
	}
	if len(peerAddresses) == 0 {
		return nil, errors.New("no punch peer candidates")
	}

	probe := buildProbePacket(probeMagic, sessionID, token)
	ack := buildProbePacket(probeAckMagic, sessionID, token)
	buffer := make([]byte, 1500)
	var provisional *net.UDPAddr
	nextSend := time.Now()

	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			_ = socket.SetReadDeadline(time.Time{})
			return nil, err
		}
		now := time.Now()
		if !now.Before(nextSend) {
			for _, peer := range peerAddresses {
				_, _ = socket.WriteToUDP(probe, peer)
			}
			nextSend = now.Add(probeInterval)
		}

		readDeadline := nextSend
		if readDeadline.After(deadline) {
			readDeadline = deadline
		}
		_ = socket.SetReadDeadline(readDeadline)
		count, source, err := socket.ReadFromUDP(buffer)
		if err != nil {
			continue
		}
		switch parseProbePacket(buffer[:count], sessionID, token) {
		case probeKindProbe:
			_, _ = socket.WriteToUDP(ack, source)
			if provisional == nil {
				provisional = source
			}
		case probeKindAck:
			lingerAck(socket, ack, source)
			_ = socket.SetReadDeadline(time.Time{})
			return source, nil
		}
	}

	_ = socket.SetReadDeadline(time.Time{})
	if provisional != nil {
		// QUIC is the definitive bidirectional reachability check.
		return provisional, nil
	}
	return nil, ErrPunchTimeout
}

func lingerAck(socket *net.UDPConn, ack []byte, destination *net.UDPAddr) {
	for count := 0; count < 3; count++ {
		_, _ = socket.WriteToUDP(ack, destination)
		time.Sleep(20 * time.Millisecond)
	}
}
