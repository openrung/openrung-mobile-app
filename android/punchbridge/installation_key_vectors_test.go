package libbox

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/openrung/openrung/brokerapi"
)

// The Android Keystore and iOS SecKey both produce ASN.1 DER ECDSA signatures
// and their own public-key spellings (Android: SubjectPublicKeyInfo; iOS: the
// X9.63 uncompressed point). Each platform converts natively to what
// OpenRungInstallationKey promises: a DER SPKI and a raw 64-byte r||s. These
// vectors pin that conversion at the wire format: this test proves every raw
// signature and the SPKI are accepted by brokerapi exactly as the broker
// verifies them, and the Kotlin and Swift suites prove their converters map
// each DER signature and point onto these bytes.
const installationKeyVectorsPath = "../../testdata/installation-key-vectors.json"

type installationKeyVectors struct {
	Comment    string                   `json:"comment"`
	SPKI       string                   `json:"spki_der_hex"`
	X963Point  string                   `json:"x963_point_hex"`
	Signatures []installationKeySigCase `json:"signatures"`
	InvalidDER []installationKeyBadCase `json:"invalid_der"`
}

type installationKeySigCase struct {
	Name      string `json:"name"`
	Challenge string `json:"challenge"`
	Digest    string `json:"digest_hex"`
	DER       string `json:"der_signature_hex"`
	Raw       string `json:"raw_signature_hex"`
}

type installationKeyBadCase struct {
	Name string `json:"name"`
	DER  string `json:"der_hex"`
}

func TestInstallationKeyVectorsVerifyWithBrokerAPI(t *testing.T) {
	if os.Getenv("UPDATE_INSTALLATION_KEY_VECTORS") == "1" {
		writeInstallationKeyVectors(t)
	}
	raw, err := os.ReadFile(installationKeyVectorsPath)
	if err != nil {
		t.Fatal(err)
	}
	var vectors installationKeyVectors
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	spki := mustHex(t, vectors.SPKI)
	parsed, err := x509.ParsePKIXPublicKey(spki)
	if err != nil {
		t.Fatal(err)
	}
	pub, ok := parsed.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		t.Fatal("vector key is not P-256")
	}
	point, err := pub.Bytes()
	if err != nil || !bytes.Equal(point, mustHex(t, vectors.X963Point)) {
		t.Fatal("SPKI and X9.63 point disagree")
	}
	canonical, err := brokerapi.CanonicalUserPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	if len(vectors.Signatures) < 4 || len(vectors.InvalidDER) < 4 {
		t.Fatal("vector coverage shrank")
	}
	for _, c := range vectors.Signatures {
		digest := sha256.Sum256(brokerapi.UserAuthStatement(c.Challenge, canonical))
		if hex.EncodeToString(digest[:]) != c.Digest {
			t.Fatalf("%s: digest is not the user-auth statement digest", c.Name)
		}
		rawSig := mustHex(t, c.Raw)
		if !brokerapi.VerifyUserAuth(pub, c.Challenge, base64.StdEncoding.EncodeToString(rawSig)) {
			t.Fatalf("%s: raw signature rejected by brokerapi", c.Name)
		}
		der := mustHex(t, c.DER)
		if !ecdsa.VerifyASN1(pub, digest[:], der) {
			t.Fatalf("%s: DER signature does not verify", c.Name)
		}
		var sig struct{ R, S *big.Int }
		if rest, err := asn1.Unmarshal(der, &sig); err != nil || len(rest) != 0 {
			t.Fatalf("%s: DER does not parse", c.Name)
		}
		want := make([]byte, 64)
		sig.R.FillBytes(want[:32])
		sig.S.FillBytes(want[32:])
		if !bytes.Equal(want, rawSig) {
			t.Fatalf("%s: raw signature is not the DER signature's r||s", c.Name)
		}
		// The exact connectcore path: SignUserAuthWith with a native signer.
		request, err := brokerapi.SignUserAuthWith(spki, c.Challenge, func(d []byte) ([]byte, error) {
			if !bytes.Equal(d, digest[:]) {
				return nil, fmt.Errorf("unexpected digest")
			}
			return rawSig, nil
		})
		if err != nil || request.Signature != base64.StdEncoding.EncodeToString(rawSig) {
			t.Fatalf("%s: SignUserAuthWith refused the native signature: %v", c.Name, err)
		}
	}
	for _, c := range vectors.InvalidDER {
		var sig struct{ R, S *big.Int }
		rest, err := asn1.Unmarshal(mustHex(t, c.DER), &sig)
		if err == nil && len(rest) == 0 && sig.R.Sign() > 0 && sig.S.Sign() > 0 && sig.R.BitLen() <= 256 && sig.S.BitLen() <= 256 {
			t.Fatalf("%s: invalid DER case is a valid P-256 signature", c.Name)
		}
	}
}

func mustHex(t *testing.T, value string) []byte {
	t.Helper()
	out, err := hex.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// writeInstallationKeyVectors regenerates the vectors with a fresh key. Only
// run it deliberately (UPDATE_INSTALLATION_KEY_VECTORS=1); the platform
// suites read the same file.
func writeInstallationKeyVectors(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	point, err := key.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := brokerapi.CanonicalUserPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	// DER INTEGERs are minimal and signed, so r and s take 31..33 bytes:
	// a leading 0x00 pad when the high bit is set, fewer bytes when the
	// top byte is zero. Cover each shape on both halves.
	shapes := []struct {
		name string
		want func(r, s []byte) bool
	}{
		{"both high bit (33-byte DER integers)", func(r, s []byte) bool { return r[0] >= 0x80 && s[0] >= 0x80 }},
		{"both 32-byte DER integers", func(r, s []byte) bool { return r[0] > 0 && r[0] < 0x80 && s[0] > 0 && s[0] < 0x80 }},
		{"short r (leading zero byte)", func(r, s []byte) bool { return r[0] == 0 && s[0] != 0 }},
		{"short s (leading zero byte)", func(r, s []byte) bool { return s[0] == 0 && r[0] != 0 }},
	}
	vectors := installationKeyVectors{
		Comment: "Generated by android/punchbridge/installation_key_vectors_test.go (UPDATE_INSTALLATION_KEY_VECTORS=1). " +
			"A test-only P-256 key. digest_hex = SHA-256 of brokerapi.UserAuthStatement(challenge, canonical key); " +
			"der_signature_hex is what the Android Keystore / iOS SecKey return; raw_signature_hex is the r||s form " +
			"OpenRungInstallationKey.Sign must return. invalid_der must be rejected by both platform converters.",
		SPKI:      hex.EncodeToString(spki),
		X963Point: hex.EncodeToString(point),
	}
	for i, shape := range shapes {
		for attempt := 0; ; attempt++ {
			if attempt > 100000 {
				t.Fatalf("no signature with shape %q", shape.name)
			}
			challenge := fmt.Sprintf("vector-%d-%d", i, attempt)
			digest := sha256.Sum256(brokerapi.UserAuthStatement(challenge, canonical))
			r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
			if err != nil {
				t.Fatal(err)
			}
			raw := make([]byte, 64)
			r.FillBytes(raw[:32])
			s.FillBytes(raw[32:])
			if !shape.want(raw[:32], raw[32:]) {
				continue
			}
			der, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
			if err != nil {
				t.Fatal(err)
			}
			vectors.Signatures = append(vectors.Signatures, installationKeySigCase{Name: shape.name, Challenge: challenge,
				Digest: hex.EncodeToString(digest[:]), DER: hex.EncodeToString(der), Raw: hex.EncodeToString(raw)})
			break
		}
	}
	valid := mustHex(t, vectors.Signatures[0].DER)
	tooLong := append([]byte{0x30, 0x46, 0x02, 0x21, 0x01}, bytes.Repeat([]byte{0x11}, 32)...)
	tooLong = append(tooLong, 0x02, 0x21, 0x00)
	tooLong = append(tooLong, bytes.Repeat([]byte{0x81}, 32)...)
	vectors.InvalidDER = []installationKeyBadCase{
		{"empty", ""},
		{"trailing byte after the sequence", hex.EncodeToString(append(append([]byte{}, valid...), 0x00))},
		{"truncated", hex.EncodeToString(valid[:len(valid)-1])},
		{"not a sequence", hex.EncodeToString(append([]byte{0x31}, valid[1:]...))},
		{"r wider than 32 bytes", hex.EncodeToString(tooLong)},
		{"negative r", "3006020181020101"},
		{"zero s", "3006020101020100"},
	}
	out, err := json.MarshalIndent(vectors, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Clean(installationKeyVectorsPath), append(out, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}
