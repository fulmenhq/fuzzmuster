// Command fuzzmuster plans, runs and verifies fuzz campaigns over native
// fuzzing engines. This build implements the version, envinfo and doctor
// commands.
package main

import (
	"context"
	"fmt"
	"os"

	appidentityembed "github.com/fulmenhq/fuzzmuster/internal/assets/appidentity"
	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/foundry"
	"github.com/fulmenhq/gofulmen/signals"
	"go.uber.org/zap"

	"github.com/fulmenhq/fuzzmuster/internal/cmd"
	"github.com/fulmenhq/fuzzmuster/internal/config"
	"github.com/fulmenhq/fuzzmuster/internal/runtime"
)

// Set at link time by the Makefile (-X main.version=... and so on). Empty
// values are resolved from the build information Go records in the binary.
var (
	version   = ""
	commit    = ""
	buildDate = ""
)

func main() {
	ctx := context.Background()

	// Register the embedded app identity so the binary works outside the
	// repository.
	if err := appidentityembed.Register(); err != nil {
		fmt.Fprintf(os.Stderr, "fuzzmuster: failed to register embedded app identity: %v\n", err)
		os.Exit(foundry.ExitConfigInvalid)
	}

	identity, err := appidentity.Get(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fuzzmuster: failed to load app identity: %v\n", err)
		os.Exit(foundry.ExitConfigInvalid)
	}

	logger := runtime.SetupLogging(identity)

	signals.OnShutdown(func(ctx context.Context) error {
		logger.Debug("shutting down")
		return nil
	})
	_ = signals.EnableDoubleTap(signals.DoubleTapConfig{})
	go func() {
		if err := signals.Listen(ctx); err != nil {
			logger.Error("signal listener failed", zap.Error(err))
		}
	}()

	cfg, err := config.LoadConfig(ctx, identity, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fuzzmuster: %v\n", err)
		os.Exit(foundry.ExitConfigInvalid)
	}

	cmd.SetVersionInfo(version, commit, buildDate)
	cmd.Initialize(ctx, identity, logger, cfg)
	if err := cmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", identity.BinaryName, err)
		code := cmd.ExitCode(err)
		if code == foundry.ExitUsage {
			fmt.Fprintf(os.Stderr, "Run '%s --help' for usage.\n", identity.BinaryName)
		}
		os.Exit(code)
	}
	os.Exit(foundry.ExitSuccess)
}
