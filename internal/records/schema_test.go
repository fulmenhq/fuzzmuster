package records

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/santhosh-tekuri/jsonschema/v5"
	"gopkg.in/yaml.v3"
)

var root = filepath.Join("..", "..")

const base = "https://schemas.fulmenhq.dev/fuzzmuster/v0/"

// compiler registers the copied crucible schemas under their own $id and the
// fuzzmuster v0 schemas under theirs, so every $ref resolves locally.
func compiler(t *testing.T) *jsonschema.Compiler {
	t.Helper()
	c := jsonschema.NewCompiler()
	c.Draft = jsonschema.Draft2020
	add := func(path string) {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var head struct {
			ID string `json:"$id"`
		}
		if err := json.Unmarshal(raw, &head); err != nil || head.ID == "" {
			t.Fatalf("%s: no $id (%v)", path, err)
		}
		if err := c.AddResource(head.ID, strings.NewReader(string(raw))); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
	}
	for _, rel := range []string{
		"durable-record/v1/record.schema.json",
		"durable-runner/v0/task-definition.schema.json",
		"record-collection/v0/record-collection.schema.json",
	} {
		add(filepath.Join(root, "schemas", "third_party", "crucible", "schemas", filepath.FromSlash(rel)))
	}
	matches, err := filepath.Glob(filepath.Join(root, "schemas", "fuzzmuster", "v0", "*.schema.json"))
	if err != nil || len(matches) == 0 {
		t.Fatalf("no v0 schemas: %v", err)
	}
	for _, m := range matches {
		add(m)
	}
	return c
}

type schemas struct {
	project, plan, manifest, campaign, attempt, report, record, collection *jsonschema.Schema
}

func compileAll(t *testing.T) schemas {
	t.Helper()
	c := compiler(t)
	get := func(id string) *jsonschema.Schema {
		s, err := c.Compile(id)
		if err != nil {
			t.Fatalf("%s does not compile: %v", id, err)
		}
		return s
	}
	return schemas{
		project:    get(base + "project.schema.json"),
		plan:       get(base + "plan.schema.json"),
		manifest:   get(base + "seed-manifest.schema.json"),
		campaign:   get(base + "campaign.schema.json"),
		attempt:    get(base + "attempt.schema.json"),
		report:     get(base + "verify-report.schema.json"),
		record:     get("contract:durable-record/v1/record.schema.json"),
		collection: get("contract:record-collection/v0/record-collection.schema.json"),
	}
}

func readJSON(t *testing.T, path string) any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return v
}

// yamlToJSON decodes YAML and round-trips it through encoding/json so the
// validator sees the same types it would for a JSON document.
func yamlToJSON(t *testing.T, path string) any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var v any
	if err := yaml.Unmarshal(raw, &v); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func fixtures(parts ...string) string {
	return filepath.Join(append([]string{root, "testdata", "fixtures", "v0"}, parts...)...)
}

func TestExampleProjectFileValidates(t *testing.T) {
	s := compileAll(t)
	doc := yamlToJSON(t, filepath.Join(root, "examples", "toyparse", "fuzzmuster.yaml"))
	if err := s.project.Validate(doc); err != nil {
		t.Fatal(err)
	}
}

func TestPlansAndManifestsValidate(t *testing.T) {
	s := compileAll(t)
	plans, _ := filepath.Glob(fixtures("plans", "*.plan.json"))
	manifests, _ := filepath.Glob(fixtures("plans", "seed-manifests", "*.json"))
	if len(plans) == 0 || len(manifests) == 0 {
		t.Fatal("no plan or manifest fixtures")
	}
	for _, p := range plans {
		if err := s.plan.Validate(readJSON(t, p)); err != nil {
			t.Errorf("%s: %v", p, err)
		}
	}
	for _, m := range manifests {
		if err := s.manifest.Validate(readJSON(t, m)); err != nil {
			t.Errorf("%s: %v", m, err)
		}
	}
}

// Every record in every case is a valid durable-record/v1 record whose
// payload validates against the schema its payload_contract names. The
// negative cases are invalid in content, never in shape.
func TestCaseRecordsValidate(t *testing.T) {
	s := compileAll(t)
	payloads := map[string]*jsonschema.Schema{
		"contract: record-collection/v0":   s.collection,
		"contract: fuzzmuster-campaign/v0": s.campaign,
		"contract: fuzzmuster-attempt/v0":  s.attempt,
	}
	cases, _ := filepath.Glob(fixtures("cases", "*"))
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	for _, dir := range cases {
		files, _ := filepath.Glob(filepath.Join(dir, "bundle", "records", "*.json"))
		files = append(files, filepath.Join(dir, "bundle", "bundle.json"))
		for _, f := range files {
			doc := readJSON(t, f)
			if err := s.record.Validate(doc); err != nil {
				t.Errorf("%s: record: %v", f, err)
				continue
			}
			rec := doc.(map[string]any)
			ps, ok := payloads[rec["payload_contract"].(string)]
			if !ok {
				t.Errorf("%s: unknown payload contract %q", f, rec["payload_contract"])
				continue
			}
			if err := ps.Validate(rec["payload"]); err != nil {
				t.Errorf("%s: payload: %v", f, err)
			}
		}
		if err := s.report.Validate(readJSON(t, filepath.Join(dir, "expected.json"))); err != nil {
			t.Errorf("%s: expected.json: %v", dir, err)
		}
	}
}

// Each case directory has exactly a case.json naming an existing plan, an
// expected.json and a bundle.
func TestCaseInventory(t *testing.T) {
	cases, _ := filepath.Glob(fixtures("cases", "*"))
	var names []string
	for _, dir := range cases {
		names = append(names, filepath.Base(dir))
		var meta struct {
			Plan        string `json:"plan"`
			Description string `json:"description"`
		}
		raw, err := os.ReadFile(filepath.Join(dir, "case.json"))
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, &meta); err != nil || meta.Plan == "" || meta.Description == "" {
			t.Errorf("%s: incomplete case.json (%v)", dir, err)
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, filepath.FromSlash(meta.Plan))); err != nil {
			t.Errorf("%s: plan: %v", dir, err)
		}
	}
	sort.Strings(names)
	want := []string{
		"attempt-wrong-job", "changed-artifact", "changed-body", "complete-clean",
		"conflicting-attempts", "corpus-not-encrypted", "disposition-attempt-mismatch",
		"identity-mismatch", "incomplete-with-finding", "limit-not-demonstrated",
		"member-unresolved", "missing-disposition", "plan-mismatch",
		"private-body-not-encrypted", "public-log-in-mutate", "retry-complete",
		"retry-repeated-finding-id", "short-budget", "uncited-attempt", "unreferenced-body", "unsupported-host",
	}
	if fmt.Sprint(names) != fmt.Sprint(want) {
		t.Errorf("cases = %v, want %v", names, want)
	}
}

// clone deep-copies a JSON value.
func clone(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// at walks a path of map keys and array indexes.
func at(v any, path ...any) any {
	for _, p := range path {
		switch k := p.(type) {
		case string:
			v = v.(map[string]any)[k]
		case int:
			v = v.([]any)[k]
		}
	}
	return v
}

func obj(v any, path ...any) map[string]any { return at(v, path...).(map[string]any) }

// artifactIndex returns the index of the first artifact with the given role.
func artifactIndex(d any, role string) int {
	for i, a := range at(d, "artifacts").([]any) {
		if a.(map[string]any)["role"] == role {
			return i
		}
	}
	panic("no artifact with role " + role)
}

// Each reject differs from a valid baseline in one place and must fail.
func TestSchemasRefuseOneChangeRejects(t *testing.T) {
	s := compileAll(t)
	project := yamlToJSON(t, filepath.Join(root, "examples", "toyparse", "fuzzmuster.yaml"))
	plan := readJSON(t, fixtures("plans", "toyparse-linux-mutate.plan.json"))
	clean := fixtures("cases", "incomplete-with-finding", "bundle", "records")
	var campaign, attempt any
	files, _ := filepath.Glob(filepath.Join(clean, "*.json"))
	for _, f := range files {
		rec := readJSON(t, f).(map[string]any)
		switch rec["payload_contract"] {
		case "contract: fuzzmuster-campaign/v0":
			campaign = rec["payload"]
		case "contract: fuzzmuster-attempt/v0":
			if len(at(rec, "payload", "observations", "findings").([]any)) > 0 {
				attempt = rec["payload"]
			}
		}
	}
	if campaign == nil || attempt == nil {
		t.Fatal("baseline payloads not found")
	}
	for name, base := range map[string]struct {
		s   *jsonschema.Schema
		doc any
	}{"project": {s.project, project}, "plan": {s.plan, plan}, "campaign": {s.campaign, campaign}, "attempt": {s.attempt, attempt}} {
		if err := base.s.Validate(base.doc); err != nil {
			t.Fatalf("%s baseline invalid: %v", name, err)
		}
	}

	rejects := []struct {
		name   string
		s      *jsonschema.Schema
		doc    any
		mutate func(any)
	}{
		{"project: unknown key", s.project, project, func(d any) { obj(d)["workers"] = "host" }},
		{"project: mutate profile without budget", s.project, project, func(d any) { delete(obj(d, "profiles", "linux-mutate"), "budget") }},
		{"project: replay profile with budget", s.project, project, func(d any) {
			obj(d, "profiles", "public")["budget"] = map[string]any{"per_target": "PT1H"}
		}},
		{"project: absolute seeds path", s.project, project, func(d any) { obj(d, "targets", 0)["seeds"] = "/srv/seeds" }},
		{"project: parent seeds path", s.project, project, func(d any) { obj(d, "targets", 0)["seeds"] = "fuzz/../../x" }},
		{"project: control with both values", s.project, project, func(d any) {
			obj(d, "profiles", "linux-mutate", "requires", 0)["mebibytes"] = 1
		}},
		{"project: control without value", s.project, project, func(d any) {
			delete(obj(d, "profiles", "linux-mutate", "requires", 1), "mebibytes")
		}},
		{"project: unknown control", s.project, project, func(d any) {
			obj(d, "profiles", "linux-mutate", "requires", 2)["control"] = "sandbox"
		}},
		{"plan: no jobs", s.plan, plan, func(d any) { obj(d)["jobs"] = []any{} }},
		{"plan: short revision", s.plan, plan, func(d any) { obj(d, "source")["revision"] = "0123abc" }},
		{"plan: non-canonical duration", s.plan, plan, func(d any) { obj(d, "budget")["per_job"] = "1h" }},
		{"plan: platform extra field", s.plan, plan, func(d any) { obj(d, "platform")["host"] = "worker1" }},
		{"plan: uppercase digest", s.plan, plan, func(d any) {
			obj(d, "project")["file_digest"] = "sha256:" + strings.Repeat("A", 64)
		}},
		{"campaign: not_started with attempt", s.campaign, campaign, func(d any) {
			j := obj(d, "jobs", 2)
			j["state"], j["budget_reached"] = "not_started", false
		}},
		{"campaign: started without attempt", s.campaign, campaign, func(d any) { delete(obj(d, "jobs", 0), "attempt") }},
		{"campaign: unsupported without missing", s.campaign, campaign, func(d any) { obj(d, "host_check")["status"] = "unsupported" }},
		{"campaign: unknown state", s.campaign, campaign, func(d any) { obj(d, "jobs", 0)["state"] = "passed" }},
		{"attempt: extra top-level field", s.attempt, attempt, func(d any) { obj(d)["stack_trace"] = "..." }},
		{"attempt: finding carries bytes", s.attempt, attempt, func(d any) {
			obj(d, "observations", "findings", 0)["data"] = "AAAA"
		}},
		{"attempt: finding input without digest", s.attempt, attempt, func(d any) {
			delete(obj(d, "observations", "findings", 0, "input"), "digest")
		}},
		{"attempt: finding input without encryption", s.attempt, attempt, func(d any) {
			delete(obj(d, "observations", "findings", 0, "input"), "encryption")
		}},
		{"attempt: minimized input without encryption", s.attempt, attempt, func(d any) {
			f := obj(d, "observations", "findings", 0)
			m := clone(t, f["input"]).(map[string]any)
			delete(m, "encryption")
			f["minimized"] = m
		}},
		{"attempt: encryption carries key material", s.attempt, attempt, func(d any) {
			obj(d, "observations", "findings", 0, "input", "encryption")["key"] = "AAAA"
		}},
		{"attempt: finding_input artifact without encryption", s.attempt, attempt, func(d any) {
			delete(obj(d, "artifacts", artifactIndex(d, "finding_input"), "body"), "encryption")
		}},
		{"attempt: finding_minimized artifact without encryption", s.attempt, attempt, func(d any) {
			a := obj(d, "artifacts", artifactIndex(d, "finding_input"))
			a["role"] = "finding_minimized"
			delete(obj(a, "body"), "encryption")
		}},
		{"attempt: unknown finding kind", s.attempt, attempt, func(d any) { obj(d, "observations", "findings", 0)["kind"] = "bug" }},
		{"attempt: limit without enforced_by", s.attempt, attempt, func(d any) {
			delete(obj(d, "worker_claims", "limits", 0), "enforced_by")
		}},
		{"attempt: non-canonical instant", s.attempt, attempt, func(d any) {
			obj(d, "worker_claims")["started_at"] = "2026-11-26T10:00:00Z"
		}},
		{"attempt: zero attempt_n", s.attempt, attempt, func(d any) { obj(d)["attempt_n"] = 0 }},
		{"attempt: artifact without custody", s.attempt, attempt, func(d any) { delete(obj(d, "artifacts", 0), "custody") }},
	}
	for _, r := range rejects {
		doc := clone(t, r.doc)
		r.mutate(doc)
		if err := r.s.Validate(doc); err == nil {
			t.Errorf("%s: accepted", r.name)
		}
	}
}

// The verify report schema binds the three facts to the exit code and
// refuses reports that contradict themselves.
func TestReportSchemaRefusesInconsistentReports(t *testing.T) {
	s := compileAll(t)
	valid := readJSON(t, fixtures("cases", "complete-clean", "expected.json"))
	invalid := readJSON(t, fixtures("cases", "changed-artifact", "expected.json"))
	finding := readJSON(t, fixtures("cases", "incomplete-with-finding", "expected.json"))
	incomplete := readJSON(t, fixtures("cases", "unsupported-host", "expected.json"))
	for _, r := range []struct {
		name   string
		doc    any
		mutate func(any)
	}{
		{"valid with a problem", valid, func(d any) {
			obj(d, "validity")["problems"] = []any{map[string]any{"code": "plan_mismatch"}}
		}},
		{"invalid without problems", invalid, func(d any) { obj(d, "validity")["problems"] = []any{} }},
		{"unknown problem code", invalid, func(d any) { obj(d, "validity", "problems", 0)["code"] = "tampered" }},
		{"unknown exit code", valid, func(d any) { obj(d)["exit_code"] = 2 }},
		{"invalid with assessed completeness and exit 0", invalid, func(d any) {
			obj(d)["completeness"] = clone(t, obj(valid, "completeness"))
			obj(d)["exit_code"] = 0
		}},
		{"invalid with exit 0", invalid, func(d any) { obj(d)["exit_code"] = 0 }},
		{"valid with not_assessed observations", valid, func(d any) {
			obj(d)["observations"] = map[string]any{"status": "not_assessed"}
		}},
		{"reported observations without basis", valid, func(d any) { delete(obj(d, "observations"), "basis") }},
		{"finding reported with exit 0", finding, func(d any) { obj(d)["exit_code"] = 0 }},
		{"finding count without findings", finding, func(d any) { obj(d, "observations")["findings"] = []any{} }},
		{"complete without findings exiting 93", valid, func(d any) { obj(d)["exit_code"] = 93 }},
		{"incomplete without findings exiting 0", incomplete, func(d any) { obj(d)["exit_code"] = 0 }},
		{"finding without attempt reference", finding, func(d any) {
			delete(obj(d, "observations", "findings", 0), "attempt_id")
		}},
		{"job metrics without subject build", valid, func(d any) {
			delete(obj(d, "observations", "jobs", 0), "subject_binary")
		}},
	} {
		doc := clone(t, r.doc)
		r.mutate(doc)
		if err := s.report.Validate(doc); err == nil {
			t.Errorf("%s: accepted", r.name)
		}
	}
}
