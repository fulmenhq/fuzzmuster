package cmd

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/santhosh-tekuri/jsonschema/v5"
)

// compileVersionSchema compiles the committed schema, so output is validated
// against the published document (types, constants, lengths and the
// extended/plain branches), not against the Go struct.
func compileVersionSchema(t *testing.T) *jsonschema.Schema {
	t.Helper()
	c := jsonschema.NewCompiler()
	c.Draft = jsonschema.Draft2020
	s, err := c.Compile(filepath.Join("..", "..", "schemas", "fuzzmuster", "v0", "version.schema.json"))
	if err != nil {
		t.Fatalf("schema does not compile: %v", err)
	}
	return s
}

func validate(t *testing.T, s *jsonschema.Schema, doc string) error {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(doc), &v); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, doc)
	}
	return s.Validate(v)
}

func TestVersionJSONValidatesAgainstSchema(t *testing.T) {
	s := compileVersionSchema(t)
	for _, args := range [][]string{
		{"version", "--format", "json"},
		{"version", "--format", "json", "--extended"},
	} {
		_, out, err := runRoot(t, fixtureInfo(), args...)
		if err != nil {
			t.Fatal(err)
		}
		if err := validate(t, s, out); err != nil {
			t.Errorf("%v: output does not validate: %v", args, err)
		}
	}
	bi := fixtureInfo()
	bi.VCSModified, bi.CGOEnabled, bi.Modules = nil, nil, nil
	_, out, _ := runRoot(t, bi, "version", "--format", "json", "--extended")
	if err := validate(t, s, out); err != nil {
		t.Errorf("unknown facts: output does not validate: %v", err)
	}
}

// Hand-written documents the schema must refuse.
func TestVersionSchemaRefusesInvalidDocuments(t *testing.T) {
	s := compileVersionSchema(t)
	id := `"$schema": "https://schemas.fulmenhq.dev/fuzzmuster/v0/version.schema.json"`
	full := `"commit": "c", "build_date": "d", "vcs_modified": null, "go_version": "go1", "os": "linux", "arch": "amd64", "cgo_enabled": false, "main_module": "m", "modules": []`
	for name, doc := range map[string]string{
		"extended field on a plain report": `{` + id + `, "name": "fuzzmuster", "version": "1", "extended": false, "commit": "c"}`,
		"extended report missing a field":  `{` + id + `, "name": "fuzzmuster", "version": "1", "extended": true, "commit": "c"}`,
		"wrong name":                       `{` + id + `, "name": "other", "version": "1", "extended": false}`,
		"empty version":                    `{` + id + `, "name": "fuzzmuster", "version": "", "extended": false}`,
		"unknown key":                      `{` + id + `, "name": "fuzzmuster", "version": "1", "extended": false, "x": 1}`,
		"modules null":                     `{` + id + `, "name": "fuzzmuster", "version": "1", "extended": true, ` + strings.Replace(full, `"modules": []`, `"modules": null`, 1) + `}`,
		"cgo as string":                    `{` + id + `, "name": "fuzzmuster", "version": "1", "extended": true, ` + strings.Replace(full, `"cgo_enabled": false`, `"cgo_enabled": "no"`, 1) + `}`,
	} {
		if err := validate(t, s, doc); err == nil {
			t.Errorf("%s: schema accepted %s", name, doc)
		}
	}
	ok := `{` + id + `, "name": "fuzzmuster", "version": "1", "extended": true, ` + full + `}`
	if err := validate(t, s, ok); err != nil {
		t.Fatalf("control document refused: %v", err)
	}
}
