package cmd

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/fulmenhq/gofulmen/appidentity"
	"github.com/spf13/cobra"

	"github.com/fulmenhq/fuzzmuster/internal/buildinfo"
)

// VersionSchemaID identifies the JSON document `version --format json` writes.
const VersionSchemaID = "https://schemas.fulmenhq.dev/fuzzmuster/v0/version.schema.json"

var info = buildinfo.Resolve(buildinfo.Linked{})

// SetVersionInfo records the link-time version, commit and build date
// (called from main). Values not injected are resolved from the build
// information the Go toolchain recorded in the binary.
func SetVersionInfo(v, c, b string) {
	info = buildinfo.Resolve(buildinfo.Linked{Version: v, Commit: c, BuildDate: b})
}

// versionDoc is the JSON projection of the version report. Extended fields
// are present only with --extended; a null boolean means the build did not
// record that fact.
type versionDoc struct {
	Schema      string              `json:"$schema"`
	Name        string              `json:"name"`
	Version     string              `json:"version"`
	Extended    bool                `json:"extended"`
	Commit      *string             `json:"commit,omitempty"`
	BuildDate   *string             `json:"build_date,omitempty"`
	VCSModified *nullableBool       `json:"vcs_modified,omitempty"`
	GoVersion   *string             `json:"go_version,omitempty"`
	OS          *string             `json:"os,omitempty"`
	Arch        *string             `json:"arch,omitempty"`
	CGOEnabled  *nullableBool       `json:"cgo_enabled,omitempty"`
	MainModule  *string             `json:"main_module,omitempty"`
	Modules     *[]buildinfo.Module `json:"modules,omitempty"`
}

// nullableBool marshals a missing value as JSON null rather than omitting it.
type nullableBool struct{ v *bool }

func (n nullableBool) MarshalJSON() ([]byte, error) { return json.Marshal(n.v) }

// newVersionCmd creates the version command
func newVersionCmd(identity *appidentity.Identity) *cobra.Command {
	var extended bool
	var format string
	name := identity.BinaryName
	cmd := &cobra.Command{
		Use:   "version",
		Short: "Print version information",
		Long: `Print the version. --extended adds the source revision, build date,
toolchain, platform, cgo setting and the modules compiled into the binary.
--format json writes a document described by
schemas/fuzzmuster/v0/version.schema.json.`,
		Args: noArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			switch format {
			case "text":
				return writeVersionText(out, name, info, extended)
			case "json":
				return writeVersionJSON(out, name, info, extended)
			default:
				return &UsageError{fmt.Errorf("unsupported --format %q (use text or json)", format)}
			}
		},
	}
	cmd.Flags().BoolVarP(&extended, "extended", "e", false, "include build, toolchain, platform and module details")
	cmd.Flags().StringVar(&format, "format", "text", "output format: text or json")
	return cmd
}

func writeVersionText(w io.Writer, name string, info buildinfo.Info, extended bool) error {
	if !extended {
		_, err := fmt.Fprintf(w, "%s %s\n", name, info.Version)
		return err
	}
	lines := [][2]string{
		{"Application", name},
		{"Version", info.Version},
		{"Commit", info.Commit},
		{"Build date", info.BuildDate},
		{"Modified tree", boolText(info.VCSModified)},
		{"Go version", info.GoVersion},
		{"Platform", info.OS + "/" + info.Arch},
		{"cgo", boolText(info.CGOEnabled)},
		{"Main module", orUnknown(info.MainModule)},
	}
	for _, l := range lines {
		if _, err := fmt.Fprintf(w, "%-14s %s\n", l[0]+":", l[1]); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintf(w, "%-14s %d\n", "Modules:", len(info.Modules)); err != nil {
		return err
	}
	for _, m := range info.Modules {
		if _, err := fmt.Fprintf(w, "  %s %s\n", m.Path, m.Version); err != nil {
			return err
		}
	}
	return nil
}

func writeVersionJSON(w io.Writer, name string, info buildinfo.Info, extended bool) error {
	doc := versionDoc{Schema: VersionSchemaID, Name: name, Version: info.Version, Extended: extended}
	if extended {
		modules := info.Modules
		if modules == nil {
			modules = []buildinfo.Module{}
		}
		main := orUnknown(info.MainModule)
		doc.Commit = &info.Commit
		doc.BuildDate = &info.BuildDate
		doc.VCSModified = &nullableBool{info.VCSModified}
		doc.GoVersion = &info.GoVersion
		doc.OS = &info.OS
		doc.Arch = &info.Arch
		doc.CGOEnabled = &nullableBool{info.CGOEnabled}
		doc.MainModule = &main
		doc.Modules = &modules
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(doc)
}

func boolText(b *bool) string {
	if b == nil {
		return "unknown"
	}
	if *b {
		return "yes"
	}
	return "no"
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}
