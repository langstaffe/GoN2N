package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/kanami/gon2n/internal/client"
	"github.com/kanami/gon2n/internal/config"
	"github.com/kanami/gon2n/internal/members"
)

const version = "0.1.0"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "gon2n:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		printUsage()
		return nil
	}

	switch args[0] {
	case "init":
		return runInit(args[1:])
	case "connect":
		return runConnect(args[1:])
	case "check":
		return runCheck(args[1:])
	case "args":
		return runArgs(args[1:])
	case "member-server":
		return runMemberServer(args[1:])
	case "version", "--version", "-v":
		fmt.Println(version)
		return nil
	case "help", "--help", "-h":
		printUsage()
		return nil
	default:
		return fmt.Errorf("unknown command %q; run gon2n help", args[0])
	}
}

func runMemberServer(args []string) error {
	fs := flag.NewFlagSet("member-server", flag.ContinueOnError)
	listen := fs.String("listen", ":51874", "HTTP listen address")
	lease := fs.Duration("lease", members.DefaultLease, "member lease duration")
	memberSecret := fs.String("member-secret", "", "member service secret for encrypted member API (or GON2N_MEMBER_SERVER_SECRET)")
	sharedSecret := fs.String("shared-secret", "", "deprecated alias for --member-secret")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *lease < 10*time.Second {
		return errors.New("lease must be at least 10s")
	}
	secret := *memberSecret
	if strings.TrimSpace(secret) == "" {
		secret = os.Getenv("GON2N_MEMBER_SERVER_SECRET")
	}
	if strings.TrimSpace(secret) == "" {
		secret = *sharedSecret
	}
	if strings.TrimSpace(secret) == "" {
		secret = os.Getenv("GON2N_SHARED_SECRET")
	}
	if strings.TrimSpace(secret) == "" {
		return errors.New("member secret is required; set GON2N_MEMBER_SERVER_SECRET or pass --member-secret")
	}
	server, err := members.NewServerWithSharedSecret(*lease, secret)
	if err != nil {
		return err
	}
	if strings.TrimSpace(secret) == "" {
		fmt.Printf("member server listening on %s, lease %s\n", *listen, *lease)
	} else {
		fmt.Printf("member server listening on %s, lease %s, encrypted member API enabled\n", *listen, *lease)
	}
	return server.ListenAndServe(*listen)
}

func runInit(args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	output := fs.String("config", "gon2n.json", "configuration file to create")
	force := fs.Bool("force", false, "overwrite an existing file")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if !*force {
		if _, err := os.Stat(*output); err == nil {
			return fmt.Errorf("%s already exists (use --force to overwrite)", *output)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}

	cfg := config.Example()
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.WriteFile(*output, data, 0o600); err != nil {
		return err
	}
	fmt.Printf("created %s\n", *output)
	fmt.Println("edit the virtual IP and supernode, then set N2N_KEY before connecting")
	return nil
}

func runConnect(args []string) error {
	fs := flag.NewFlagSet("connect", flag.ContinueOnError)
	configPath := fs.String("config", "gon2n.json", "configuration file")
	edgePath := fs.String("edge", "", "path to the n2n edge executable")
	dryRun := fs.Bool("dry-run", false, "validate and print the command without starting it")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	runner, err := client.New(cfg, *edgePath)
	if err != nil {
		return err
	}
	if *dryRun {
		fmt.Println(runner.DisplayCommand())
		return nil
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	fmt.Printf("joining community %q as %s via %s\n", cfg.Community, cfg.Address, strings.Join(cfg.Supernodes, ", "))
	return runner.Run(ctx, os.Stdin, os.Stdout, os.Stderr)
}

func runArgs(args []string) error {
	fs := flag.NewFlagSet("args", flag.ContinueOnError)
	configPath := fs.String("config", "gon2n.json", "configuration file")
	edgePath := fs.String("edge", "", "path to the n2n edge executable")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	runner, err := client.New(cfg, *edgePath)
	if err != nil {
		return err
	}
	fmt.Println(runner.DisplayCommand())
	return nil
}

func runCheck(args []string) error {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	configPath := fs.String("config", "gon2n.json", "configuration file")
	edgePath := fs.String("edge", "", "path to the n2n edge executable")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	runner, err := client.New(cfg, *edgePath)
	if err != nil {
		return err
	}

	fmt.Printf("config:      OK (%s)\n", filepath.Clean(*configPath))
	fmt.Printf("edge binary: OK (%s)\n", runner.EdgePath())
	if privilegeWarning() != "" {
		fmt.Println("privileges:  WARN (edge normally requires root or CAP_NET_ADMIN)")
	} else {
		fmt.Println("privileges:  OK")
	}
	if cfg.KeyEnv != "" {
		fmt.Printf("key:         OK (from %s)\n", cfg.KeyEnv)
	}

	cmd := exec.Command(runner.EdgePath(), "--version")
	if output, cmdErr := cmd.CombinedOutput(); cmdErr == nil && len(output) > 0 {
		fmt.Printf("edge version: %s", output)
	}
	return nil
}

func printUsage() {
	fmt.Print(`gon2n - Go client controller for ntop/n2n

Usage:
  gon2n init [--config gon2n.json]
  gon2n check [--config gon2n.json] [--edge /path/to/edge]
  gon2n connect [--config gon2n.json] [--edge /path/to/edge] [--dry-run]
  gon2n args [--config gon2n.json] [--edge /path/to/edge]
  gon2n member-server [--listen :51874] [--lease 30s] [--member-secret secret]
  gon2n version
`)
}
