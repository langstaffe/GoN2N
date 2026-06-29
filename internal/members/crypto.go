package members

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

const (
	secureEnvelopeVersion = 1
	secureEnvelopeMaxAge  = 2 * time.Minute
)

var (
	secureSalt       = []byte("gon2n-member-service-v1")
	secureKeyInfo    = []byte("gon2n-member-key")
	secureBodyInfo   = []byte("gon2n-member-body-v1")
	secureReplayInfo = []byte("gon2n-member-replay-v1")
)

type secureEnvelope struct {
	Version    int    `json:"version"`
	Nonce      string `json:"nonce"`
	Timestamp  int64  `json:"timestamp"`
	Ciphertext string `json:"ciphertext"`
	MAC        string `json:"mac"`
}

type secureCodec struct {
	encKey    []byte
	macKey    []byte
	replayKey []byte
	now       func() time.Time
}

func newSecureCodec(sharedSecret string, now func() time.Time) (*secureCodec, error) {
	sharedSecret = strings.TrimSpace(sharedSecret)
	if sharedSecret == "" {
		return nil, nil
	}
	if now == nil {
		now = time.Now
	}
	memberKey := hkdfSHA256([]byte(sharedSecret), secureSalt, secureKeyInfo, 32)
	bodyKey := hkdfSHA256(memberKey, secureSalt, secureBodyInfo, 64)
	replayKey := hkdfSHA256(memberKey, secureSalt, secureReplayInfo, 32)
	return &secureCodec{
		encKey:    bodyKey[:32],
		macKey:    bodyKey[32:],
		replayKey: replayKey,
		now:       now,
	}, nil
}

func (c *secureCodec) seal(value any) ([]byte, error) {
	plain, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	env := secureEnvelope{
		Version:   secureEnvelopeVersion,
		Nonce:     base64.RawURLEncoding.EncodeToString(nonce),
		Timestamp: c.now().UTC().Unix(),
	}
	ciphertext := xorWithHMACStream(c.encKey, nonce, plain)
	env.Ciphertext = base64.RawURLEncoding.EncodeToString(ciphertext)
	env.MAC = base64.RawURLEncoding.EncodeToString(c.envelopeMAC(env, ciphertext))
	return json.Marshal(env)
}

func (c *secureCodec) open(data []byte, target any) (string, error) {
	var env secureEnvelope
	if err := json.Unmarshal(data, &env); err != nil {
		return "", err
	}
	if env.Version != secureEnvelopeVersion {
		return "", fmt.Errorf("unsupported encrypted envelope version %d", env.Version)
	}
	nonce, err := base64.RawURLEncoding.DecodeString(env.Nonce)
	if err != nil || len(nonce) != 16 {
		return "", errors.New("invalid encrypted envelope nonce")
	}
	ciphertext, err := base64.RawURLEncoding.DecodeString(env.Ciphertext)
	if err != nil {
		return "", errors.New("invalid encrypted envelope ciphertext")
	}
	gotMAC, err := base64.RawURLEncoding.DecodeString(env.MAC)
	if err != nil {
		return "", errors.New("invalid encrypted envelope mac")
	}
	wantMAC := c.envelopeMAC(env, ciphertext)
	if subtle.ConstantTimeCompare(gotMAC, wantMAC) != 1 {
		return "", errors.New("invalid encrypted envelope mac")
	}
	createdAt := time.Unix(env.Timestamp, 0)
	now := c.now().UTC()
	if createdAt.Before(now.Add(-secureEnvelopeMaxAge)) ||
		createdAt.After(now.Add(secureEnvelopeMaxAge)) {
		return "", errors.New("encrypted envelope timestamp is outside the allowed window")
	}
	plain := xorWithHMACStream(c.encKey, nonce, ciphertext)
	if err := json.Unmarshal(plain, target); err != nil {
		return "", err
	}
	return c.replayID(nonce, env.Timestamp), nil
}

func (c *secureCodec) envelopeMAC(env secureEnvelope, ciphertext []byte) []byte {
	mac := hmac.New(sha256.New, c.macKey)
	mac.Write([]byte(fmt.Sprintf("%d\n%d\n%s\n", env.Version, env.Timestamp, env.Nonce)))
	mac.Write(ciphertext)
	return mac.Sum(nil)
}

func (c *secureCodec) replayID(nonce []byte, timestamp int64) string {
	mac := hmac.New(sha256.New, c.replayKey)
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], uint64(timestamp))
	mac.Write(buf[:])
	mac.Write(nonce)
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func xorWithHMACStream(key, nonce, input []byte) []byte {
	output := make([]byte, len(input))
	var counter uint32
	var offset int
	for offset < len(input) {
		mac := hmac.New(sha256.New, key)
		mac.Write(nonce)
		var counterBytes [4]byte
		binary.BigEndian.PutUint32(counterBytes[:], counter)
		mac.Write(counterBytes[:])
		block := mac.Sum(nil)
		for i := 0; i < len(block) && offset < len(input); i++ {
			output[offset] = input[offset] ^ block[i]
			offset++
		}
		counter++
	}
	return output
}

func hkdfSHA256(secret, salt, info []byte, length int) []byte {
	extractor := hmac.New(sha256.New, salt)
	extractor.Write(secret)
	prk := extractor.Sum(nil)

	result := make([]byte, 0, length)
	var previous []byte
	for counter := byte(1); len(result) < length; counter++ {
		expander := hmac.New(sha256.New, prk)
		expander.Write(previous)
		expander.Write(info)
		expander.Write([]byte{counter})
		previous = expander.Sum(nil)
		result = append(result, previous...)
	}
	return result[:length]
}
