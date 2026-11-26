package config

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/logging"
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

// LoadConfig loads the operator configuration. The file is optional. It is
// decoded strictly: an unknown key is an error.
func LoadConfig(ctx context.Context, identity *appidentity.Identity, logger *logging.Logger) (*Config, error) {
	_ = ctx
	cfg := &Config{}

	configPath, err := ConfigPath(identity)
	if err != nil {
		return nil, err
	}
	switch _, err := os.Lstat(configPath); {
	case errors.Is(err, fs.ErrNotExist):
		return cfg, nil
	case err != nil:
		// Any other failure is not "absent": a file that cannot be checked
		// is never silently ignored.
		return nil, fmt.Errorf("cannot check config file %s: %w", configPath, err)
	}
	data, err := readUserConfig(configPath)
	if err != nil {
		if strings.Contains(err.Error(), "escapes from parent") {
			return nil, fmt.Errorf("config file %s resolves outside the user config directory; a symlink out of it is refused", configPath)
		}
		return nil, fmt.Errorf("cannot read config file %s: %w", configPath, err)
	}
	if err := decodeStrict(data, cfg); err != nil {
		return nil, fmt.Errorf("cannot parse config file %s: %w", configPath, err)
	}
	logger.Debug("loaded config from file", zap.String("path", configPath))
	return cfg, nil
}

// ConfigPath returns the operator configuration file location.
func ConfigPath(identity *appidentity.Identity) (string, error) {
	return userConfigPath(identity)
}

// decodeStrict decodes YAML and refuses keys the Config type does not define.
// An empty document is accepted.
func decodeStrict(data []byte, cfg *Config) error {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(cfg); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

// userConfigPath returns the config file path under the user's .config directory.
func userConfigPath(identity *appidentity.Identity) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to resolve home directory: %w", err)
	}
	path := filepath.Join(homeDir, ".config", identity.Vendor, identity.ConfigName+".yaml")
	return cleanUserConfigPath(homeDir, path)
}

func cleanUserConfigPath(homeDir, path string) (string, error) {
	root := filepath.Join(homeDir, ".config")
	clean := filepath.Clean(path)
	rel, err := filepath.Rel(root, clean)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", fmt.Errorf("config path is outside the user config directory")
	}
	return clean, nil
}

func readUserConfig(path string) ([]byte, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	clean, err := cleanUserConfigPath(homeDir, path)
	if err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(filepath.Join(homeDir, ".config"))
	if err != nil {
		return nil, err
	}
	defer func() { _ = root.Close() }()
	rel, err := filepath.Rel(filepath.Join(homeDir, ".config"), clean)
	if err != nil {
		return nil, err
	}
	f, err := root.Open(rel)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	return io.ReadAll(f)
}
