package config

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/logging"
)

func testIdentity() *appidentity.Identity {
	return &appidentity.Identity{
		BinaryName: "fuzzmuster",
		Vendor:     "fulmenhq",
		EnvPrefix:  "FUZZMUSTER_",
		ConfigName: "fuzzmuster",
	}
}

func writeConfig(t *testing.T, identity *appidentity.Identity, data string) {
	t.Helper()
	configPath, err := userConfigPath(identity)
	if err != nil {
		t.Fatalf("userConfigPath returned error: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("failed to create config dir: %v", err)
	}
	if err := os.WriteFile(configPath, []byte(data), 0o644); err != nil {
		t.Fatalf("failed to write config file: %v", err)
	}
}

func TestLoadConfig_NoFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	identity := testIdentity()
	logger, err := logging.NewCLI(identity.BinaryName)
	if err != nil {
		t.Fatalf("logger init failed: %v", err)
	}
	if _, err := LoadConfig(context.Background(), identity, logger); err != nil {
		t.Fatalf("LoadConfig without a file returned error: %v", err)
	}
}

func TestLoadConfig_EmptyFileAccepted(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	identity := testIdentity()
	logger, _ := logging.NewCLI(identity.BinaryName)
	writeConfig(t, identity, "# no settings yet\n")
	if _, err := LoadConfig(context.Background(), identity, logger); err != nil {
		t.Fatalf("LoadConfig with an empty file returned error: %v", err)
	}
}

func TestLoadConfig_UnknownKeyRefused(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	identity := testIdentity()
	logger, _ := logging.NewCLI(identity.BinaryName)
	writeConfig(t, identity, "max_depth: 3\n")
	if _, err := LoadConfig(context.Background(), identity, logger); err == nil {
		t.Fatal("expected an unknown key to be refused")
	}
}

func TestUserConfigPath_RejectsEscape(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	outside := filepath.Join(home, "secret.yaml")
	if err := os.WriteFile(outside, []byte("unused: true\n"), 0o644); err != nil {
		t.Fatalf("write outside file: %v", err)
	}

	identity := &appidentity.Identity{
		BinaryName: "fuzzmuster",
		Vendor:     "..",
		EnvPrefix:  "FUZZMUSTER_",
		ConfigName: "secret",
	}
	if _, err := userConfigPath(identity); err == nil {
		t.Fatal("expected config path outside ~/.config to be rejected")
	}
	if _, err := readUserConfig(outside); err == nil {
		t.Fatal("expected a read outside ~/.config to be rejected")
	}
}

func TestReadUserConfig_RejectsSymlinkEscape(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	configDir := filepath.Join(home, ".config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("mkdir config: %v", err)
	}
	outside := filepath.Join(home, "secret.yaml")
	if err := os.WriteFile(outside, []byte("unused: true\n"), 0o644); err != nil {
		t.Fatalf("write outside file: %v", err)
	}
	link := filepath.Join(configDir, "escape.yaml")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	if _, err := readUserConfig(link); err == nil {
		t.Fatal("symlink under ~/.config pointing outside was accepted")
	}
}
