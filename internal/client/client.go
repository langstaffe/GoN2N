package client

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/kanami/gon2n/internal/config"
)

type Runner struct {
	config   config.Config
	edgePath string
	args     []string
	env      []string
}

func New(cfg config.Config, edgePath string) (*Runner, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}
	if edgePath == "" {
		var err error
		edgePath, err = exec.LookPath("edge")
		if err != nil {
			return nil, fmt.Errorf("n2n edge executable not found in PATH; install ntop/n2n or pass --edge: %w", err)
		}
	} else {
		resolved, err := exec.LookPath(edgePath)
		if err != nil {
			return nil, fmt.Errorf("find edge executable: %w", err)
		}
		edgePath = resolved
	}

	args := buildArgs(cfg)
	env := append(os.Environ(),
		"N2N_COMMUNITY="+cfg.Community,
		"N2N_KEY="+os.Getenv(cfg.KeyEnv),
	)
	return &Runner{config: cfg, edgePath: edgePath, args: args, env: env}, nil
}

func buildArgs(cfg config.Config) []string {
	args := []string{"-a", "static:" + cfg.Address}
	for _, supernode := range cfg.Supernodes {
		args = append(args, "-l", supernode)
	}
	if cfg.Device != "" {
		args = append(args, "-d", cfg.Device)
	}
	if cfg.MAC != "" {
		args = append(args, "-m", cfg.MAC)
	}
	if cfg.LocalPort > 0 {
		args = append(args, "-p", strconv.Itoa(cfg.LocalPort))
	}
	if cfg.RegisterEvery > 0 {
		args = append(args, "-i", strconv.Itoa(cfg.RegisterEvery))
	}
	if cfg.MTU > 0 {
		args = append(args, "-M", strconv.Itoa(cfg.MTU))
	}
	if cfg.AcceptMulticast {
		args = append(args, "-E")
	}
	if cfg.AllowRouting {
		args = append(args, "-r")
	}
	if cfg.ForceRelay {
		args = append(args, "-S1")
	}
	if cfg.HeaderEncryption {
		args = append(args, "-H")
	}
	for range cfg.Verbose {
		args = append(args, "-v")
	}
	return append(args, cfg.ExtraArgs...)
}

func (r *Runner) EdgePath() string {
	return r.edgePath
}

func (r *Runner) DisplayCommand() string {
	parts := []string{
		fmt.Sprintf("N2N_COMMUNITY=%s", shellQuote(r.config.Community)),
		"N2N_KEY=<redacted>",
		shellQuote(r.edgePath),
	}
	for _, arg := range r.args {
		parts = append(parts, shellQuote(arg))
	}
	return strings.Join(parts, " ")
}

func (r *Runner) Run(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer) error {
	cmd := exec.CommandContext(ctx, r.edgePath, r.args...)
	cmd.Env = r.env
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("edge exited: %w", err)
	}
	return nil
}

func shellQuote(value string) string {
	if value != "" && !strings.ContainsAny(value, " \t\r\n'\"\\$`;&|<>()*?![]{}") {
		return value
	}
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
