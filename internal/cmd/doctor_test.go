package cmd

import (
	"errors"
	"strings"
	"testing"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/fulmenhq/gofulmen/foundry"
)

func TestDoctorReportsAtEveryLogLevel(t *testing.T) {
	for _, level := range []string{"info", "warn", "error"} {
		r := runWith(t, fixtureInfo(), nil, "--log-level", level, "doctor")
		if r.code != foundry.ExitSuccess || r.stdout != "" {
			t.Fatalf("%s: code=%d stdout=%q err=%v", level, r.code, r.stdout, r.err)
		}
		for _, want := range []string{"[1/2] App identity: ok", "[2/2] Configuration: ok", "Installation checks passed"} {
			if !strings.Contains(r.stderr, want) {
				t.Errorf("%s: stderr lacks %q:\n%s", level, want, r.stderr)
			}
		}
	}
	t.Setenv("FUZZMUSTER_LOG_LEVEL", "error")
	if r := runWith(t, fixtureInfo(), nil, "doctor"); !strings.Contains(r.stderr, "Installation checks passed") {
		t.Fatalf("FUZZMUSTER_LOG_LEVEL=error silenced doctor: %q", r.stderr)
	}
}

func TestDoctorReportsAConfigError(t *testing.T) {
	r := runWith(t, fixtureInfo(), errors.New("cannot parse config file"), "doctor")
	if r.code != foundry.ExitConfigInvalid {
		t.Fatalf("code=%d, want %d", r.code, foundry.ExitConfigInvalid)
	}
	if !strings.Contains(r.stderr, "[2/2] Configuration: FAIL (cannot parse config file)") || strings.Contains(r.stderr, "checks passed") {
		t.Fatalf("stderr:\n%s", r.stderr)
	}
}

func TestDoctorRefusesAnIncompleteIdentity(t *testing.T) {
	setHome(t)
	cmd := newDoctorCmd(&appidentity.Identity{BinaryName: "fuzzmuster"})
	var errb strings.Builder
	cmd.SetErr(&errb)
	cmd.SilenceUsage = true
	cmd.SetArgs(nil)
	err := cmd.Execute()
	if err == nil || ExitCode(err) != foundry.ExitFailure || !strings.Contains(errb.String(), "App identity: FAIL") {
		t.Fatalf("err=%v stderr=%q", err, errb.String())
	}
}

func TestEnvinfoReportsAtEveryLogLevel(t *testing.T) {
	for _, level := range []string{"info", "error"} {
		r := runWith(t, fixtureInfo(), nil, "--log-level", level, "envinfo")
		if r.code != foundry.ExitSuccess || r.stdout != "" {
			t.Fatalf("%s: code=%d stdout=%q", level, r.code, r.stdout)
		}
		for _, want := range []string{"=== fuzzmuster environment ===", "Version:      0.1.0", "Commit:       abc123", "(absent; none is needed)"} {
			if !strings.Contains(r.stderr, want) {
				t.Errorf("%s: stderr lacks %q:\n%s", level, want, r.stderr)
			}
		}
	}
}

func TestEnvinfoShowsAConfigError(t *testing.T) {
	r := runWith(t, fixtureInfo(), errors.New("bad key"), "envinfo")
	if r.code != foundry.ExitSuccess || !strings.Contains(r.stderr, "(invalid: bad key)") {
		t.Fatalf("code=%d stderr:\n%s", r.code, r.stderr)
	}
}

func TestConfigErrorAllowsOnlyReportingCommands(t *testing.T) {
	cfgErr := errors.New("bad config")
	for _, args := range [][]string{{"version"}, {}, {"help"}, {"--help"}, {"envinfo"}} {
		if r := runWith(t, fixtureInfo(), cfgErr, args...); r.code != foundry.ExitSuccess {
			t.Errorf("%v: code=%d err=%v", args, r.code, r.err)
		}
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

func TestReportWriteFailureFailsTheCommand(t *testing.T) {
	for _, name := range []string{"doctor", "envinfo"} {
		setHome(t)
		var cmd = newDoctorCmd(testIdentity())
		if name == "envinfo" {
			cmd = newEnvinfoCmd(testIdentity())
		}
		cmd.SilenceUsage = true
		cmd.SetErr(failingWriter{})
		cmd.SetArgs(nil)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "cannot write report") {
			t.Errorf("%s: err=%v", name, err)
		}
	}
}
