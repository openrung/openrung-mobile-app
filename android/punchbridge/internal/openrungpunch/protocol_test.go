package openrungpunch

import (
	"bytes"
	"testing"
)

func TestProbePacketAuthentication(t *testing.T) {
	token := bytes.Repeat([]byte{0x42}, tokenLen)
	packet := buildProbePacket(probeMagic, "session-1", token)
	if got := parseProbePacket(packet, "session-1", token); got != probeKindProbe {
		t.Fatalf("probe kind = %v", got)
	}
	badToken := append([]byte(nil), token...)
	badToken[0] ^= 0xff
	if got := parseProbePacket(packet, "session-1", badToken); got != probeKindNone {
		t.Fatalf("bad token accepted as %v", got)
	}
	if got := parseProbePacket(packet, "other-session", token); got != probeKindNone {
		t.Fatalf("bad session accepted as %v", got)
	}
}

func TestSanitizePeersDropsPublicHostAndCapsReflexiveTarget(t *testing.T) {
	input := []Endpoint{
		{IP: "8.8.8.8", Port: 53, Kind: KindHost},
		{IP: "192.168.1.10", Port: 1234, Kind: KindHost},
		{IP: "224.0.0.1", Port: 9999, Kind: KindSrflx},
		{IP: "203.0.113.8", Port: 443, Kind: "bogus"},
	}
	for index := 0; index < maxPunchPeers+3; index++ {
		input = append(input, Endpoint{
			IP:   "198.51.100.1",
			Port: 20_000 + index,
			Kind: KindSrflx,
		})
	}
	input = append(input, Endpoint{IP: "198.51.100.2", Port: 30_000, Kind: KindSrflx})

	got := SanitizePeers(input)
	var hosts, reflexive int
	for _, endpoint := range got {
		switch endpoint.Kind {
		case KindHost:
			hosts++
			if endpoint.IP != "192.168.1.10" {
				t.Fatalf("unexpected host candidate: %+v", endpoint)
			}
		case KindSrflx:
			reflexive++
			if endpoint.IP != "198.51.100.1" {
				t.Fatalf("reflexive target fanned out to another public IP: %+v", endpoint)
			}
		}
	}
	if hosts != 1 || reflexive != maxPunchPeers {
		t.Fatalf("host=%d reflexive=%d candidates=%+v", hosts, reflexive, got)
	}
}
