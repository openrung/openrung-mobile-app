package openrungpunch

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strconv"
	"time"
)

const (
	gatherTimeout   = 2 * time.Second
	gatherRounds    = 4
	gatherRoundWait = 250 * time.Millisecond
)

func GenerateNonce() (hexNonce string, raw []byte, err error) {
	raw = make([]byte, reflectNonceLen)
	if _, err = rand.Read(raw); err != nil {
		return "", nil, fmt.Errorf("generate punch nonce: %w", err)
	}
	return hex.EncodeToString(raw), raw, nil
}

// Gather probes every reflector from the exact socket later used for punching
// and QUIC. A stable mapped port across two reflector IPs is EIM; differing
// ports identify a symmetric mapping.
func Gather(
	ctx context.Context,
	socket *net.UDPConn,
	reflectorAddresses []string,
	nonce []byte,
) ([]Endpoint, string, error) {
	if len(reflectorAddresses) == 0 {
		return nil, ClassUnknown, errors.New("no reflector addresses")
	}
	targets := make([]*net.UDPAddr, 0, len(reflectorAddresses))
	keys := make([]string, 0, len(reflectorAddresses))
	for _, address := range reflectorAddresses {
		host, portValue, err := net.SplitHostPort(address)
		if err != nil {
			continue
		}
		ip := net.ParseIP(host)
		port, portError := strconv.Atoi(portValue)
		// The retained socket is udp4, and deployed reflector addresses are
		// signed literal IPv4 tuples. Rejecting coordinator-controlled DNS names
		// also keeps Close cancellation from getting stuck in an uncancelable
		// net.ResolveUDPAddr lookup.
		if ip == nil || ip.To4() == nil || !isGloballyRoutable(ip) || portError != nil || !inRange(port, 1, 65535) {
			continue
		}
		target := &net.UDPAddr{IP: ip.To4(), Port: port}
		targets = append(targets, target)
		keys = append(keys, address)
	}
	if len(targets) == 0 {
		return nil, ClassUnknown, errors.New("no resolvable reflector addresses")
	}

	observed := make(map[string]Endpoint)
	buffer := make([]byte, 1500)
	overallDeadline := time.Now().Add(gatherTimeout)
	for round := 0; round < gatherRounds && len(observed) < len(targets) && time.Now().Before(overallDeadline); round++ {
		if err := ctx.Err(); err != nil {
			return nil, ClassUnknown, err
		}
		for index, target := range targets {
			if _, done := observed[keys[index]]; done {
				continue
			}
			_, _ = socket.WriteToUDP(buildReflectRequest(nonce), target)
		}

		roundDeadline := time.Now().Add(gatherRoundWait)
		if roundDeadline.After(overallDeadline) {
			roundDeadline = overallDeadline
		}
		_ = socket.SetReadDeadline(roundDeadline)
		for time.Now().Before(roundDeadline) {
			count, source, err := socket.ReadFromUDP(buffer)
			if err != nil {
				break
			}
			replyNonce, endpoint, valid := parseReflectReply(buffer[:count])
			if !valid || !bytes.Equal(replyNonce, nonce) {
				continue
			}
			if key := matchingReflector(source, targets, keys); key != "" {
				observed[key] = endpointFromUDP(endpoint, KindSrflx)
			}
		}
	}
	_ = socket.SetReadDeadline(time.Time{})

	reflexive := make([]Endpoint, 0, len(observed))
	ports := make(map[int]struct{})
	for _, endpoint := range observed {
		reflexive = append(reflexive, endpoint)
		ports[endpoint.Port] = struct{}{}
	}
	reflexive = dedupeEndpoints(reflexive)
	natClass := ClassUnknown
	switch {
	case len(observed) < 2:
		natClass = ClassUnknown
	case len(ports) == 1:
		natClass = ClassEIM
	default:
		natClass = ClassSymmetric
	}
	if len(reflexive) == 0 {
		return nil, natClass, errors.New("reflector did not observe any endpoint")
	}
	return reflexive, natClass, nil
}

func inRange(value, minimum, maximum int) bool {
	return value >= minimum && value <= maximum
}

func matchingReflector(source *net.UDPAddr, targets []*net.UDPAddr, keys []string) string {
	for index, target := range targets {
		if target.Port == source.Port && target.IP.Equal(source.IP) {
			return keys[index]
		}
	}
	return ""
}
