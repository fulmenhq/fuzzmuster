package buildinfo

import (
	"runtime/debug"
	"testing"
)

func TestResolveDefaultsWithoutBuildInfo(t *testing.T) {
	info := resolve(Linked{}, nil, "linux", "amd64")
	if info.Version != "dev" || info.Commit != "unknown" || info.BuildDate != "unknown" {
		t.Fatalf("defaults: got %+v", info)
	}
	if info.OS != "linux" || info.Arch != "amd64" {
		t.Fatalf("platform: got %s/%s", info.OS, info.Arch)
	}
	if info.VCSModified != nil || info.CGOEnabled != nil {
		t.Fatalf("unrecorded settings must stay unknown, got %+v", info)
	}
	if info.Modules == nil || len(info.Modules) != 0 {
		t.Fatalf("modules must be an empty list, got %#v", info.Modules)
	}
}

func TestResolveReadsModuleVersionAndVCSStamp(t *testing.T) {
	bi := &debug.BuildInfo{
		GoVersion: "go1.26.10",
		Main:      debug.Module{Path: "github.com/fulmenhq/fuzzmuster", Version: "v0.1.0"},
		Deps: []*debug.Module{
			{Path: "example.com/b", Version: "v1.0.0", Sum: "h1:b"},
			{Path: "example.com/a", Version: "v1.0.0", Replace: &debug.Module{Path: "example.com/a-fork", Version: "v1.0.1"}},
		},
		Settings: []debug.BuildSetting{
			{Key: "vcs.revision", Value: "abc123"},
			{Key: "vcs.time", Value: "2026-11-25T00:00:00Z"},
			{Key: "vcs.modified", Value: "true"},
			{Key: "CGO_ENABLED", Value: "0"},
		},
	}
	info := resolve(Linked{}, bi, "darwin", "arm64")
	if info.Version != "v0.1.0" || info.Commit != "abc123" || info.BuildDate != "2026-11-25T00:00:00Z" {
		t.Fatalf("got %+v", info)
	}
	if info.GoVersion != "go1.26.10" || info.MainModule != "github.com/fulmenhq/fuzzmuster" {
		t.Fatalf("got %+v", info)
	}
	if info.VCSModified == nil || !*info.VCSModified {
		t.Fatal("vcs.modified=true not reported")
	}
	if info.CGOEnabled == nil || *info.CGOEnabled {
		t.Fatal("CGO_ENABLED=0 not reported as false")
	}
	if len(info.Modules) != 2 || info.Modules[0].Path != "example.com/a-fork" || info.Modules[1].Path != "example.com/b" {
		t.Fatalf("modules must be sorted and use the replacement: %+v", info.Modules)
	}
}

func TestResolveDevelVersionIsDev(t *testing.T) {
	bi := &debug.BuildInfo{Main: debug.Module{Version: "(devel)"}}
	if got := resolve(Linked{}, bi, "linux", "arm64").Version; got != "dev" {
		t.Fatalf("got %q", got)
	}
}

func TestLinkedValuesWin(t *testing.T) {
	bi := &debug.BuildInfo{
		Main:     debug.Module{Version: "v9.9.9"},
		Settings: []debug.BuildSetting{{Key: "vcs.revision", Value: "stamp"}, {Key: "vcs.time", Value: "stamp-time"}},
	}
	info := resolve(Linked{Version: "0.1.0", Commit: "linked", BuildDate: "linked-date"}, bi, "linux", "amd64")
	if info.Version != "0.1.0" || info.Commit != "linked" || info.BuildDate != "linked-date" {
		t.Fatalf("got %+v", info)
	}
}
