package cmd

import (
	"context"
	"testing"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/logging"

	"github.com/fulmenhq/fuzzmuster/internal/config"
)

func TestDoctorCommand_Succeeds(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	identity := &appidentity.Identity{
		BinaryName:  "fuzzmuster",
		Vendor:      "fulmenhq",
		EnvPrefix:   "FUZZMUSTER_",
		ConfigName:  "fuzzmuster",
		Description: "Test tool",
	}
	logger, err := logging.NewCLI(identity.BinaryName)
	if err != nil {
		t.Fatalf("logger init failed: %v", err)
	}
	cfg := &config.Config{}
	Initialize(context.Background(), identity, logger, cfg)

	cmd := newDoctorCmd(identity)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("doctor command returned error: %v", err)
	}
}
