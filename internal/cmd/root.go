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

	// loggerInstance holds the logger (used by subcommands)
	loggerInstance *logging.Logger
)

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
	return foundry.ExitFailure
}

// Execute runs the root command
func Execute() error {
	return rootCmd.Execute()
}

// Initialize sets up the root command with app identity, logger, and config
func Initialize(ctx context.Context, identity *appidentity.Identity, logger *logging.Logger, cfg *config.Config) {
	_ = cfg
	loggerInstance = logger

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
			return applyLogLevel(logger, level)
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
