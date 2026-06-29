package config

import (
	"strings"
	"testing"
)

func validConfig(t *testing.T) Config {
	t.Helper()
	t.Setenv("TEST_N2N_KEY", "secret")
	return Config{
		Community:  "team",
		Address:    "192.168.100.10/24",
		Supernodes: []string{"127.0.0.1:7777"},
		KeyEnv:     "TEST_N2N_KEY",
	}
}

func TestValidate(t *testing.T) {
	if err := validConfig(t).Validate(); err != nil {
		t.Fatalf("expected valid config: %v", err)
	}
}

func TestExampleIsValid(t *testing.T) {
	t.Setenv("N2N_KEY", "secret")
	if err := Example().Validate(); err != nil {
		t.Fatalf("expected example config to be valid: %v", err)
	}
}

func TestValidateRejectsLongCommunity(t *testing.T) {
	cfg := validConfig(t)
	cfg.Community = strings.Repeat("x", 21)
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected long community to fail")
	}
}

func TestValidateRejectsKeyInExtraArgs(t *testing.T) {
	cfg := validConfig(t)
	cfg.ExtraArgs = []string{"-k", "leaked"}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected key in extra args to fail")
	}
}
