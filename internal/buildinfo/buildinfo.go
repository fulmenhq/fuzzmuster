// Package buildinfo reports what this fuzzmuster binary is: its version, the
// source revision it was built from, and the toolchain, platform and modules
// that went into it.
package buildinfo

import (
	"runtime"
	"runtime/debug"
	"sort"
)

// Linked holds the values injected at link time. Empty means not injected.
type Linked struct {
	Version   string
	Commit    string
	BuildDate string
}

// Module is one module compiled into the binary.
type Module struct {
	Path    string `json:"path"`
	Version string `json:"version"`
	Sum     string `json:"sum,omitempty"`
}

// Info describes the running binary.
type Info struct {
	Version     string
	Commit      string
	BuildDate   string
	VCSModified *bool
	GoVersion   string
	OS          string
	Arch        string
	CGOEnabled  *bool
	MainModule  string
	Modules     []Module
}

// Resolve combines link-time values with what the Go toolchain recorded in
// the binary. A link-time value wins. Without one, the module version (set
// by `go install module@version`) and the VCS stamp (set by `go build` in a
// checkout) are used. Anything still unknown is reported as "unknown", and
// the version as "dev".
func Resolve(linked Linked) Info {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		bi = nil
	}
	return resolve(linked, bi, runtime.GOOS, runtime.GOARCH)
}

func resolve(linked Linked, bi *debug.BuildInfo, goos, goarch string) Info {
	info := Info{
		Version:   "dev",
		Commit:    "unknown",
		BuildDate: "unknown",
		GoVersion: runtime.Version(),
		OS:        goos,
		Arch:      goarch,
	}
	if bi != nil {
		if bi.GoVersion != "" {
			info.GoVersion = bi.GoVersion
		}
		info.MainModule = bi.Main.Path
		if v := bi.Main.Version; v != "" && v != "(devel)" {
			info.Version = v
		}
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision":
				info.Commit = s.Value
			case "vcs.time":
				info.BuildDate = s.Value
			case "vcs.modified":
				b := s.Value == "true"
				info.VCSModified = &b
			case "CGO_ENABLED":
				b := s.Value == "1"
				info.CGOEnabled = &b
			}
		}
		for _, d := range bi.Deps {
			m := d
			if d.Replace != nil {
				m = d.Replace
			}
			info.Modules = append(info.Modules, Module{Path: m.Path, Version: m.Version, Sum: m.Sum})
		}
		sort.Slice(info.Modules, func(i, j int) bool { return info.Modules[i].Path < info.Modules[j].Path })
	}
	if linked.Version != "" {
		info.Version = linked.Version
	}
	if linked.Commit != "" {
		info.Commit = linked.Commit
	}
	if linked.BuildDate != "" {
		info.BuildDate = linked.BuildDate
	}
	if info.Modules == nil {
		info.Modules = []Module{}
	}
	return info
}
