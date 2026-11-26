// Package cmd implements the fuzzmuster command line: argument parsing,
// output formats and exit codes. Data goes to stdout and diagnostics, logs
// included, to stderr.
package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/foundry"
	"github.com/fulmenhq/gofulmen/logging"
	"github.com/spf13/cobra"

	"github.com/fulmenhq/fuzzmuster/internal/config"
)

var (
	// Global flags
	logLevel string

	// rootCmd represents the base command
	rootCmd *cobra.Command

	// configErr is the error from loading the operator configuration, if
	// any. Commands that need the configuration refuse to run with it;
	// version, help, envinfo and doctor still run so they can report it.
	configErr error
)

// ConfigError marks an operator configuration that could not be loaded.
type ConfigError struct{ Err error }

func (e *ConfigError) Error() string { return e.Err.Error() }
func (e *ConfigError) Unwrap() error { return e.Err }

// UsageError marks a command-line usage problem: an unknown command or flag,
// a missing or invalid flag value, or an unexpected argument.
type UsageError struct{ Err error }

func (e *UsageError) Error() string { return e.Err.Error() }
func (e *UsageError) Unwrap() error { return e.Err }

// ExitCode maps a command error to a code from the Fulmen exit-code catalog.
func ExitCode(err error) int {
	if err == nil {
		return foundry.ExitSuccess
	}
	var ue *UsageError
	if errors.As(err, &ue) || isCobraUsageError(err) {
		return foundry.ExitUsage
	}
	var ce *ConfigError
	if errors.As(err, &ce) {
		return foundry.ExitConfigInvalid
	}
	return foundry.ExitFailure
}

// Execute runs the root command
func Execute() error {
	return rootCmd.Execute()
}

// Initialize sets up the root command with app identity, logger, and the
// configuration (or the error from loading it).
func Initialize(ctx context.Context, identity *appidentity.Identity, logger *logging.Logger, cfg *config.Config, cfgErr error) {
	_ = cfg
	configErr = cfgErr

	rootCmd = &cobra.Command{
		Use:   identity.BinaryName,
		Short: identity.Description,
		Long: identity.Description + `.

fuzzmuster drives native fuzzing engines (cargo-fuzz with libFuzzer,
go test -fuzz); it does not contain one. This is an early build: only the
version, envinfo and doctor commands are implemented.`,
		Args:          noArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			level := logLevel
			if !cmd.Flags().Changed("log-level") {
				if env := os.Getenv(identity.EnvPrefix + "LOG_LEVEL"); env != "" {
					level = env
				}
			}
			if err := applyLogLevel(logger, level); err != nil {
				return err
			}
			if configErr != nil && !reportsConfig(cmd) {
				return &ConfigError{configErr}
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}
	rootCmd.SetContext(ctx)
	rootCmd.SetOut(os.Stdout)
	rootCmd.SetErr(os.Stderr)
	rootCmd.CompletionOptions.DisableDefaultCmd = true
	rootCmd.SetFlagErrorFunc(func(_ *cobra.Command, err error) error {
		return &UsageError{err}
	})

	// Global flags
	rootCmd.PersistentFlags().StringVarP(&logLevel, "log-level", "l", "info",
		"logging level (trace|debug|info|warn|error); default from "+identity.EnvPrefix+"LOG_LEVEL")

	// Add subcommands
	rootCmd.AddCommand(newVersionCmd(identity))
	rootCmd.AddCommand(newEnvinfoCmd(identity))
	rootCmd.AddCommand(newDoctorCmd(identity))
}

func applyLogLevel(logger *logging.Logger, level string) error {
	switch strings.ToUpper(level) {
	case "TRACE":
		logger.SetLevel(logging.TRACE)
	case "DEBUG":
		logger.SetLevel(logging.DEBUG)
	case "INFO", "":
		logger.SetLevel(logging.INFO)
	case "WARN", "WARNING":
		logger.SetLevel(logging.WARN)
	case "ERROR":
		logger.SetLevel(logging.ERROR)
	default:
		return &UsageError{fmt.Errorf("invalid log level %q (use trace|debug|info|warn|error)", level)}
	}
	return nil
}

// reportsConfig names the commands that run with a broken configuration:
// the root (help), help, version, and the two diagnostics that report it.
func reportsConfig(cmd *cobra.Command) bool {
	if !cmd.HasParent() {
		return true
	}
	switch cmd.Name() {
	case "help", "version", "envinfo", "doctor":
		return true
	}
	return false
}

// noArgs refuses positional arguments, including an unknown subcommand
// name, as a usage error.
func noArgs(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		return nil
	}
	if cmd.HasSubCommands() {
		return &UsageError{fmt.Errorf("unknown command %q", args[0])}
	}
	return &UsageError{fmt.Errorf("%s takes no arguments, got %q", cmd.CommandPath(), args[0])}
}

// isCobraUsageError recognises the parse errors cobra returns before a
// command runs without passing through the flag error function.
func isCobraUsageError(err error) bool {
	msg := err.Error()
	for _, prefix := range []string{"unknown command", "unknown flag", "unknown shorthand flag", "invalid argument", "flag needs an argument", "required flag"} {
		if strings.HasPrefix(msg, prefix) {
			return true
		}
	}
	return false
}
