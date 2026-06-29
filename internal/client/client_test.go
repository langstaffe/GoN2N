package client

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/kanami/gon2n/internal/config"
)

func TestBuildArgs(t *testing.T) {
	cfg := config.Config{
		Address:          "192.168.100.10/24",
		Supernodes:       []string{"one.example:7777", "two.example:7777"},
		Device:           "edge0",
		LocalPort:        12345,
		AcceptMulticast:  true,
		AllowRouting:     true,
		ForceRelay:       true,
		HeaderEncryption: true,
		Verbose:          2,
	}
	want := []string{
		"-a", "static:192.168.100.10/24",
		"-l", "one.example:7777", "-l", "two.example:7777",
		"-d", "edge0", "-p", "12345", "-E", "-r", "-S1", "-H", "-v", "-v",
	}
	if got := buildArgs(cfg); !reflect.DeepEqual(got, want) {
		t.Fatalf("args mismatch\nwant: %#v\n got: %#v", want, got)
	}
}

func TestShellQuote(t *testing.T) {
	if got := shellQuote("hello world"); got != "'hello world'" {
		t.Fatalf("unexpected quote: %s", got)
	}
}

func TestRunnerStartsEdgeWithSecretInEnvironment(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test helper uses a POSIX shell script")
	}

	t.Setenv("TEST_N2N_KEY", "shared-secret")
	edgePath := filepath.Join(t.TempDir(), "edge")
	script := "#!/bin/sh\nprintf 'community=%s\\nkey=%s\\nargs=%s\\n' \"$N2N_COMMUNITY\" \"$N2N_KEY\" \"$*\"\n"
	if err := os.WriteFile(edgePath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Community:  "team",
		Address:    "192.168.100.10/24",
		Supernodes: []string{"127.0.0.1:7777"},
		KeyEnv:     "TEST_N2N_KEY",
	}
	runner, err := New(cfg, edgePath)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := runner.Run(context.Background(), nil, &output, &output); err != nil {
		t.Fatal(err)
	}
	got := output.String()
	for _, want := range []string{
		"community=team",
		"key=shared-secret",
		"args=-a static:192.168.100.10/24 -l 127.0.0.1:7777",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("output %q does not contain %q", got, want)
		}
	}
	if strings.Contains(runner.DisplayCommand(), "shared-secret") {
		t.Fatal("display command leaked the secret")
	}
}
