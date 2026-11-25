package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/fulmenhq/gofulmen/appidentity"

	"github.com/fulmenhq/fuzzmuster/internal/config"
)

// newDoctorCmd creates the doctor command. In this build it checks only
// fuzzmuster's own installation. Fuzzing toolchains and host controls are
// not checked yet, and the output says so rather than implying a host is
// ready to fuzz. The report goes to stderr whatever the log level.
func newDoctorCmd(identity *appidentity.Identity) *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Check this fuzzmuster installation",
		Long: `Check this fuzzmuster installation: its identity and the operator
configuration. Fuzzing toolchains, engines and host controls are not checked
in this build. The report goes to stderr; the exit code is 0 when every
check passes, 20 for a configuration problem and 1 otherwise.`,
		Args: noArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			w := &report{w: cmd.ErrOrStderr()}
			w.printf("=== %s doctor ===\n", identity.BinaryName)

			if identity.BinaryName == "" || identity.Vendor == "" {
				w.println("[1/2] App identity: FAIL (incomplete)")
				return w.done(fmt.Errorf("app identity is incomplete"))
			}
			w.printf("[1/2] App identity: ok (%s, vendor %s)\n", identity.BinaryName, identity.Vendor)

			path, err := config.ConfigPath(identity)
			if err != nil {
				w.printf("[2/2] Configuration: FAIL (%v)\n", err)
				return w.done(&ConfigError{err})
			}
			if configErr != nil {
				w.printf("[2/2] Configuration: FAIL (%v)\n", configErr)
				return w.done(&ConfigError{configErr})
			}
			if _, err := os.Lstat(path); err == nil {
				w.printf("[2/2] Configuration: ok (%s)\n", path)
			} else {
				w.printf("[2/2] Configuration: ok (%s absent; none is needed)\n", path)
			}

			w.println("Installation checks passed. Fuzzing toolchains and host controls are not checked in this build.")
			return w.done(nil)
		},
	}
}
