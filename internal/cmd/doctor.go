package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
	"go.uber.org/zap"

	"github.com/fulmenhq/gofulmen/appidentity"
)

// newDoctorCmd creates the doctor command. In this build it checks only
// fuzzmuster's own installation. Fuzzing toolchains and host controls are
// not checked yet, and the output says so rather than implying a host is
// ready to fuzz.
func newDoctorCmd(identity *appidentity.Identity) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "Check this fuzzmuster installation",
		Long: `Check this fuzzmuster installation: its identity and the operator
configuration location. Fuzzing toolchains, engines and host controls are
not checked in this build.`,
		Args: noArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			name := identity.BinaryName
			loggerInstance.Info(fmt.Sprintf("=== %s doctor ===", name))

			if identity.BinaryName == "" || identity.Vendor == "" {
				loggerInstance.Error("[1/2] App identity... invalid")
				return fmt.Errorf("app identity is incomplete")
			}
			loggerInstance.Info("[1/2] App identity... ok",
				zap.String("binary_name", identity.BinaryName),
				zap.String("vendor", identity.Vendor))

			homeDir, err := os.UserHomeDir()
			if err != nil {
				loggerInstance.Error("[2/2] Config location... cannot resolve the home directory", zap.Error(err))
				return fmt.Errorf("cannot resolve the home directory: %w", err)
			}
			configFile := filepath.Join(homeDir, ".config", identity.Vendor, identity.ConfigName+".yaml")
			if _, err := os.Stat(configFile); err == nil {
				loggerInstance.Info("[2/2] Config location... "+configFile+" (present)", zap.String("config_file", configFile))
			} else {
				loggerInstance.Info("[2/2] Config location... "+configFile+" (absent; none is needed)", zap.String("config_file", configFile))
			}

			loggerInstance.Info("Installation checks passed. Fuzzing toolchains and host controls are not checked in this build.")
			return nil
		},
	}
	return cmd
}
