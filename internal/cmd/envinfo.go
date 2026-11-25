package cmd

import (
	"fmt"
	"os"
	"runtime"

	"github.com/spf13/cobra"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/crucible"

	"github.com/fulmenhq/fuzzmuster/internal/config"
)

// newEnvinfoCmd creates the envinfo command. The report goes to stderr
// whatever the log level.
func newEnvinfoCmd(identity *appidentity.Identity) *cobra.Command {
	return &cobra.Command{
		Use:   "envinfo",
		Short: "Display environment information",
		Long:  `Display version, runtime, configuration and environment information on stderr.`,
		Args:  noArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			w := &report{w: cmd.ErrOrStderr()}
			ssot := crucible.GetVersion()
			line := func(label, value string) { w.printf("  %-13s %s\n", label+":", value) }

			w.printf("=== %s environment ===\n", identity.BinaryName)
			w.println("Application:")
			line("Name", identity.BinaryName)
			line("Vendor", identity.Vendor)
			line("Description", identity.Description)
			line("Version", info.Version)
			line("Commit", info.Commit)
			line("Built", info.BuildDate)
			w.println("Libraries:")
			line("Gofulmen", "v"+ssot.Gofulmen)
			line("Crucible", "v"+ssot.Crucible)
			w.println("Runtime:")
			line("Go version", runtime.Version())
			line("Platform", runtime.GOOS+"/"+runtime.GOARCH)
			line("CPUs", fmt.Sprint(runtime.NumCPU()))
			w.println("Configuration:")
			line("Env prefix", identity.EnvPrefix)
			path, err := config.ConfigPath(identity)
			switch {
			case err != nil:
				line("Config file", "unknown ("+err.Error()+")")
			case configErr != nil:
				line("Config file", path+" (invalid: "+configErr.Error()+")")
			default:
				if _, err := os.Lstat(path); err == nil {
					line("Config file", path+" (present)")
				} else {
					line("Config file", path+" (absent; none is needed)")
				}
			}
			w.println("Environment:")
			name := identity.EnvPrefix + "LOG_LEVEL"
			if val, ok := os.LookupEnv(name); ok {
				line(name, val)
			} else {
				w.printf("  (no %s* variables set)\n", identity.EnvPrefix)
			}
			return w.done(nil)
		},
	}
}
