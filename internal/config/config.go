package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
)

const maxCommunityLength = 20

type Config struct {
	Community        string   `json:"community"`
	Address          string   `json:"address"`
	Supernodes       []string `json:"supernodes"`
	KeyEnv           string   `json:"key_env,omitempty"`
	Device           string   `json:"device,omitempty"`
	MAC              string   `json:"mac,omitempty"`
	LocalPort        int      `json:"local_port,omitempty"`
	RegisterEvery    int      `json:"register_every,omitempty"`
	MTU              int      `json:"mtu,omitempty"`
	AcceptMulticast  bool     `json:"accept_multicast,omitempty"`
	AllowRouting     bool     `json:"allow_routing,omitempty"`
	ForceRelay       bool     `json:"force_relay,omitempty"`
	HeaderEncryption bool     `json:"header_encryption,omitempty"`
	Verbose          int      `json:"verbose,omitempty"`
	ExtraArgs        []string `json:"extra_args,omitempty"`
}

func Example() Config {
	return Config{
		Community:  "private-team",
		Address:    "192.168.100.10/24",
		Supernodes: []string{"supernode.example.com:7777"},
		KeyEnv:     "N2N_KEY",
	}
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	var cfg Config
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, fmt.Errorf("invalid config: %w", err)
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if c.Community == "" {
		return errors.New("community is required")
	}
	if len(c.Community) > maxCommunityLength {
		return fmt.Errorf("community must be at most %d bytes for n2n compatibility", maxCommunityLength)
	}
	if strings.ContainsAny(c.Community, "\x00\r\n") {
		return errors.New("community contains invalid characters")
	}

	ip, network, err := net.ParseCIDR(c.Address)
	if err != nil || ip.To4() == nil {
		return fmt.Errorf("address must be an IPv4 CIDR, for example 192.168.100.10/24")
	}
	if ip.Equal(network.IP) {
		return errors.New("address cannot be the network address")
	}
	if len(c.Supernodes) == 0 {
		return errors.New("at least one supernode is required")
	}
	for _, supernode := range c.Supernodes {
		host, port, err := net.SplitHostPort(supernode)
		if err != nil || host == "" || port == "" {
			return fmt.Errorf("invalid supernode %q; expected host:port", supernode)
		}
	}
	if c.KeyEnv == "" {
		return errors.New("key_env is required; use an environment variable such as N2N_KEY")
	}
	if os.Getenv(c.KeyEnv) == "" {
		return fmt.Errorf("environment variable %s is empty", c.KeyEnv)
	}
	if c.MAC != "" {
		mac, err := net.ParseMAC(c.MAC)
		if err != nil || len(mac) != 6 {
			return fmt.Errorf("invalid MAC address %q", c.MAC)
		}
	}
	if c.LocalPort < 0 || c.LocalPort > 65535 {
		return errors.New("local_port must be between 0 and 65535")
	}
	if c.RegisterEvery < 0 {
		return errors.New("register_every cannot be negative")
	}
	if c.MTU < 0 {
		return errors.New("mtu cannot be negative")
	}
	if c.Verbose < 0 || c.Verbose > 5 {
		return errors.New("verbose must be between 0 and 5")
	}
	for _, arg := range c.ExtraArgs {
		if arg == "-k" || strings.HasPrefix(arg, "-k=") {
			return errors.New("do not put keys in extra_args; use key_env")
		}
	}
	return nil
}
