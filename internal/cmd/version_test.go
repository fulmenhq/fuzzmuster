package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/foundry"
	"github.com/fulmenhq/gofulmen/logging"

	"github.com/fulmenhq/fuzzmuster/internal/buildinfo"
	"github.com/fulmenhq/fuzzmuster/internal/config"
)

func fixtureInfo() buildinfo.Info {
	f := false
	return buildinfo.Info{
		Version: "0.1.0", Commit: "abc123", BuildDate: "2026-11-25T00:00:00Z",
		VCSModified: &f, GoVersion: "go1.26.10", OS: "linux", Arch: "amd64",
		CGOEnabled: &f, MainModule: "github.com/fulmenhq/fuzzmuster",
		Modules: []buildinfo.Module{{Path: "github.com/spf13/cobra", Version: "v1.10.2", Sum: "h1:x"}},
	}
}

func testIdentity() *appidentity.Identity {
	return &appidentity.Identity{
		BinaryName: "fuzzmuster", Vendor: "fulmenhq", EnvPrefix: "FUZZMUSTER_",
		ConfigName: "fuzzmuster", Description: "Plan, run and verify fuzz campaigns over native fuzzing engines",
	}
}

// setHome points both HOME and USERPROFILE (what os.UserHomeDir reads on
// Windows) at a fresh directory, so no test touches the real profile.
func setHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	return home
}

type result struct {
	code   int
	stdout string
	stderr string
	err    error
}

// runWith runs the full root command with the given build information and
// configuration error, and returns the exit code main would use.
func runWith(t *testing.T, bi buildinfo.Info, cfgErr error, args ...string) result {
	t.Helper()
	setHome(t)
	saved := info
	info = bi
	t.Cleanup(func() { info = saved })
	logger, err := logging.NewCLI("fuzzmuster")
	if err != nil {
		t.Fatal(err)
	}
	Initialize(context.Background(), testIdentity(), logger, &config.Config{}, cfgErr)
	var out, errb bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errb)
	rootCmd.SetArgs(args)
	err = Execute()
	return result{ExitCode(err), out.String(), errb.String(), err}
}

// runRoot runs the root command with no configuration error.
func runRoot(t *testing.T, bi buildinfo.Info, args ...string) (int, string, error) {
	t.Helper()
	r := runWith(t, bi, nil, args...)
	return r.code, r.stdout, r.err
}

func TestVersionText(t *testing.T) {
	code, out, err := runRoot(t, fixtureInfo(), "version")
	if code != foundry.ExitSuccess || out != "fuzzmuster 0.1.0\n" {
		t.Fatalf("code=%d out=%q err=%v", code, out, err)
	}
}

func TestVersionExtendedText(t *testing.T) {
	code, out, err := runRoot(t, fixtureInfo(), "version", "--extended")
	if code != foundry.ExitSuccess {
		t.Fatalf("code=%d err=%v", code, err)
	}
	for _, want := range []string{"Version:       0.1.0", "Commit:        abc123", "Platform:      linux/amd64", "cgo:           no", "Modified tree: no", "  github.com/spf13/cobra v1.10.2"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestVersionExtendedUnknownFacts(t *testing.T) {
	bi := buildinfo.Info{Version: "dev", Commit: "unknown", BuildDate: "unknown", OS: "linux", Arch: "arm64", Modules: []buildinfo.Module{}}
	code, out, _ := runRoot(t, bi, "version", "-e")
	if code != foundry.ExitSuccess || !strings.Contains(out, "cgo:           unknown") || !strings.Contains(out, "Main module:   unknown") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// loadSchema reads the committed schema so the tests check the output
// against the published document, not against the Go struct.
func loadSchema(t *testing.T) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "schemas", "fuzzmuster", "v0", "version.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var s map[string]any
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func keys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func strs(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	sort.Strings(out)
	return out
}

func decode(t *testing.T, out string) map[string]any {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, out)
	}
	return doc
}

func TestVersionJSONMatchesSchemaKeys(t *testing.T) {
	schema := loadSchema(t)
	props := schema["properties"].(map[string]any)
	required := strs(schema["required"])
	extendedRequired := strs(schema["then"].(map[string]any)["required"])

	code, out, err := runRoot(t, fixtureInfo(), "version", "--format", "json")
	if code != foundry.ExitSuccess {
		t.Fatalf("code=%d err=%v", code, err)
	}
	doc := decode(t, out)
	if got := keys(doc); !reflect.DeepEqual(got, required) {
		t.Fatalf("plain keys %v, schema requires exactly %v", got, required)
	}
	if doc["$schema"] != props["$schema"].(map[string]any)["const"] || doc["$schema"] != VersionSchemaID {
		t.Fatalf("$schema %v", doc["$schema"])
	}
	if doc["extended"] != false || doc["name"] != "fuzzmuster" || doc["version"] != "0.1.0" {
		t.Fatalf("doc %v", doc)
	}

	code, out, _ = runRoot(t, fixtureInfo(), "version", "--format", "json", "--extended")
	if code != foundry.ExitSuccess {
		t.Fatalf("code=%d", code)
	}
	doc = decode(t, out)
	want := append(append([]string{}, required...), extendedRequired...)
	sort.Strings(want)
	if got := keys(doc); !reflect.DeepEqual(got, want) {
		t.Fatalf("extended keys %v, schema requires %v", got, want)
	}
	for k := range doc {
		if _, ok := props[k]; !ok {
			t.Errorf("key %q is not in the schema", k)
		}
	}
}

func TestVersionJSONNullsForUnrecordedFacts(t *testing.T) {
	bi := fixtureInfo()
	bi.VCSModified, bi.CGOEnabled = nil, nil
	_, out, _ := runRoot(t, bi, "version", "--format", "json", "--extended")
	doc := decode(t, out)
	for _, k := range []string{"vcs_modified", "cgo_enabled"} {
		v, ok := doc[k]
		if !ok || v != nil {
			t.Errorf("%s: want present and null, got %v (present=%v)", k, v, ok)
		}
	}
}

func TestUsageErrorsExit64(t *testing.T) {
	cases := [][]string{
		{"nosuchcommand"},
		{"--nosuchflag"},
		{"version", "--format", "yaml"},
		{"version", "extra"},
		{"version", "--nosuchflag"},
		{"version", "--format"},
		{"--log-level", "loud", "version"},
		{"doctor", "extra"},
		{"envinfo", "extra"},
	}
	for _, args := range cases {
		code, out, err := runRoot(t, fixtureInfo(), args...)
		if code != foundry.ExitUsage {
			t.Errorf("%v: code=%d, want %d (err %v)", args, code, foundry.ExitUsage, err)
		}
		if out != "" {
			t.Errorf("%v: usage errors must not write to stdout, got %q", args, out)
		}
	}
}

func TestLogLevelFromEnvironment(t *testing.T) {
	t.Setenv("FUZZMUSTER_LOG_LEVEL", "loud")
	code, _, _ := runRoot(t, fixtureInfo(), "version")
	if code != foundry.ExitUsage {
		t.Fatalf("an invalid FUZZMUSTER_LOG_LEVEL must be a usage error, got %d", code)
	}
	t.Setenv("FUZZMUSTER_LOG_LEVEL", "loud")
	code, _, _ = runRoot(t, fixtureInfo(), "--log-level", "debug", "version")
	if code != foundry.ExitSuccess {
		t.Fatalf("--log-level must override the environment, got %d", code)
	}
}

func TestNoArgumentsPrintsHelp(t *testing.T) {
	code, out, err := runRoot(t, fixtureInfo())
	if code != foundry.ExitSuccess || !strings.Contains(out, "only the\nversion, envinfo and doctor commands are implemented") {
		t.Fatalf("code=%d err=%v out=%q", code, err, out)
	}
}

func TestOnlyImplementedCommandsAreListed(t *testing.T) {
	if code, _, err := runRoot(t, fixtureInfo(), "version"); code != foundry.ExitSuccess {
		t.Fatalf("version: code=%d err=%v", code, err)
	}
	var names []string
	for _, c := range rootCmd.Commands() {
		if c.IsAvailableCommand() {
			names = append(names, c.Name())
		}
	}
	sort.Strings(names)
	want := []string{"doctor", "envinfo", "version"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("available commands %v, want %v; do not list a command that is not implemented", names, want)
	}
}

func TestNoArgumentsWording(t *testing.T) {
	_, _, err := runRoot(t, fixtureInfo(), "version", "extra")
	if err == nil || err.Error() != `fuzzmuster version takes no arguments, got "extra"` {
		t.Fatalf("err=%v", err)
	}
	_, _, err = runRoot(t, fixtureInfo(), "nosuch")
	if err == nil || err.Error() != `unknown command "nosuch"` {
		t.Fatalf("err=%v", err)
	}
}

func TestIsCobraUsageError(t *testing.T) {
	for _, msg := range []string{"unknown command x", "unknown flag: --x", "unknown shorthand flag: 'x'", "invalid argument \"x\"", "flag needs an argument: --x", "required flag(s) \"x\" not set"} {
		if !isCobraUsageError(errors.New(msg)) || ExitCode(errors.New(msg)) != foundry.ExitUsage {
			t.Errorf("%q not recognised as a usage error", msg)
		}
	}
	if isCobraUsageError(errors.New("disk full")) || ExitCode(errors.New("disk full")) != foundry.ExitFailure {
		t.Error("an ordinary error was treated as a usage error")
	}
	if ExitCode(&ConfigError{errors.New("x")}) != foundry.ExitConfigInvalid || ExitCode(nil) != foundry.ExitSuccess {
		t.Error("config or nil error mapped wrongly")
	}
}

func TestLogLevels(t *testing.T) {
	logger, err := logging.NewCLI("fuzzmuster")
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]logging.Severity{
		"trace": logging.DEBUG /* gofulmen has no separate trace level */, "DEBUG": logging.DEBUG, "info": logging.INFO, "": logging.INFO,
		"warn": logging.WARN, "Warning": logging.WARN, "error": logging.ERROR,
	}
	for in, want := range cases {
		if err := applyLogLevel(logger, in); err != nil {
			t.Fatalf("%q: %v", in, err)
		}
		if got := logger.GetLevel(); got != want {
			t.Errorf("%q: level %v, want %v", in, got, want)
		}
	}
}

func TestVersionModulesNeverNull(t *testing.T) {
	bi := fixtureInfo()
	bi.Modules = nil
	_, out, _ := runRoot(t, bi, "version", "--format", "json", "--extended")
	if !strings.Contains(out, `"modules": []`) {
		t.Fatalf("modules must be an empty array:\n%s", out)
	}
	_, out, _ = runRoot(t, bi, "version", "--extended")
	if !strings.Contains(out, "Modules:       0\n") {
		t.Fatalf("text module count:\n%s", out)
	}
	_, out, _ = runRoot(t, fixtureInfo(), "version", "--extended")
	if !strings.Contains(out, "Modules:       1\n") {
		t.Fatalf("text module count:\n%s", out)
	}
}
