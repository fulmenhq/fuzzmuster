# Records v0: project file, plan and result

Status: draft for review. Nothing in this document is implemented yet. The
schemas are in [`schemas/fuzzmuster/v0/`](../../schemas/fuzzmuster/v0/), the
fixtures in [`testdata/fixtures/v0/`](../../testdata/fixtures/v0/) and the
synthetic project in [`examples/toyparse/`](../../examples/toyparse/).

fuzzmuster reads one hand-written file and writes two kinds of document:

| Document                         | Written by                                     | Trusted by                                                         |
| -------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------ |
| Project file (`fuzzmuster.yaml`) | The maintainer, checked in                     | Everyone who reviews the repository                                |
| Plan (`*.plan.json`)             | `fuzzmuster plan`, then reviewed               | The person who verifies a result; they keep their own copy         |
| Result bundle (a directory)      | `fuzzmuster run` or `replay`, then a collector | Nobody, until `fuzzmuster verify` checks it against a trusted plan |

## Three separate facts

`verify` reports three facts about a bundle, independently:

- **Validity.** The bundle is intact and consistent with the trusted plan:
  every pinned record is present and matches its digest, every bundled body
  matches its digest, every record names the trusted plan, every required job
  has exactly one disposition, and the attempt records do not contradict each
  other or the disposition that cites them.
- **Completeness.** Every required job reached its planned budget.
- **Observations.** What the attempts reported: findings, executions and
  coverage, each with the engine, unit and subject build that produced it.

A bundle can be valid and incomplete, and still hold a finding. Example: three
jobs, two reached their budget and one of them found a crash, and the third
was interrupted when its host was lost. That bundle is valid, it is
incomplete, and the finding is reported. A finished budget is a bounded
observation. It never means that no defects remain.

When a bundle is invalid, completeness and observations are reported as
`not_assessed`: nothing in an invalid bundle is relied on.

## Identities and digests

| Item            | Definition                                                                                                                          | Source                                 |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Digest          | `sha256:` and 64 lowercase hex digits                                                                                               | durable-record/v1 `$defs.digest`       |
| Document digest | SHA-256 over the RFC 8785 (JCS) bytes of the JSON document                                                                          | durable-record/v1 revision digest rule |
| Byte digest     | SHA-256 over the exact bytes of a file                                                                                              | durable-record/v1 `bodyRef.digest`     |
| Plan digest     | Document digest of the plan                                                                                                         | local, as above                        |
| Task id         | `sha256(JCS({"authority": A, "invocation_key": K, "v": 0}))`, with `A` = `fuzzmuster-plan-` + the plan digest hex, `K` = the job id | durable-runner/v0 task identity        |
| Attempt id      | `sha256(JCS({"attempt_n": N, "task_id": T, "v": 0}))`                                                                               | durable-runner/v0 attempt identity     |
| Duration        | Fixed-unit ISO 8601 subset (`PT10S`, `PT1H`, `P1D`)                                                                                 | durable-runner/v0 `$defs.duration`     |
| Instant         | UTC with exactly six fractional digits (`2026-11-26T09:00:00.000000Z`)                                                              | durable-record/v1 `$defs.instant`      |

A retry of a job gets the next attempt number under the same task id, so the
plan digest is an input to every attempt identity. Running the same plan again
continues the same tasks; changing the plan starts new ones. Operators should
know the consequence: two independent runs of the same plan, started without
seeing each other's attempts, both produce attempt 1 of each task. Collecting
them into one bundle is an `attempt_conflict`. Run a plan from one place, or
change the plan (for example its budget) for an independent run.

## Bundle layout

A result bundle is a directory:

```text
bundle.json          one durable-record/v1 record carrying a record-collection/v0 set
records/<hex>.json   one durable-record/v1 record per member, named by its digest hex
bodies/<hex>         optional bytes for a body reference, named by its byte digest hex
```

The members are one campaign record and the attempt records it cites, plus
any earlier attempts it retains. The collection's `closure_claim` is `none`:
under record-collection/v0 a `complete_at_write` claim needs resolver
evidence from the time of writing, which a file bundle does not carry. A later
offline read establishes only that every pin resolves now. Required
membership is checked against the trusted plan instead.

A body in `bodies/` is either a public artifact or the ciphertext of an
encrypted one. A private artifact that is not encrypted appears only as a
digest, a length and a media type, never as bytes.

Encryption uses the durable-record/v1 `bodyRef.encryption` fields. For an
encrypted body the digest, length and media type describe the ciphertext.
`key_ref` names the key-custody record; the key never appears in a bundle.
`verify` never decrypts and does not interpret `scheme`. Encryption is
required on:

- a finding's `input` and `minimized`, and on artifacts with the role
  `finding_input` or `finding_minimized` (schema);
- the final corpus manifest, `observations.corpus` and every
  `corpus_manifest` artifact, when the plan's profile mode is `mutate`
  (check 13).

A `mutate` profile never has an artifact with public custody (check 13). A
`replay` profile may. Reviewed seeds are pinned by the seed manifest and are
not covered by these rules.

Streams and record ids:

| Record   | Stream                | Record id                    | Payload contract                   |
| -------- | --------------------- | ---------------------------- | ---------------------------------- |
| Bundle   | `fuzzmuster.bundle`   | `bundle-<plan digest hex>`   | `contract: record-collection/v0`   |
| Campaign | `fuzzmuster.campaign` | `campaign-<plan digest hex>` | `contract: fuzzmuster-campaign/v0` |
| Attempt  | `fuzzmuster.attempt`  | `attempt-<attempt id hex>`   | `contract: fuzzmuster-attempt/v0`  |

An attempt record is written once (revision 1). When a later collection adds
a retry, the campaign and bundle records get a new revision that supersedes
the previous one.

## Verification rules

`verify <bundle> --plan <trusted plan>` reads only local files and never uses
the network. It checks, in this order, and reports every problem it finds:

1. `bundle.json` is a valid durable-record/v1 record whose payload is a valid
   record-collection/v0 `set` (canonical order, `member_count`, no repeats)
   (`bundle_invalid`).
2. Each member resolves to `records/<hex>.json` whose recomputed digest equals
   the pin (`member_unresolved`, `member_digest_mismatch`).
3. Each member is a valid durable-record/v1 record with a known payload
   contract and a valid payload (`record_invalid`).
4. Each bundled body matches its byte digest and length
   (`body_digest_mismatch`). Each bundled body is referenced by at least one
   member artifact (`body_unreferenced`), and every member artifact that
   references it is public or encrypted (`body_not_encrypted`). An absent
   body is counted as withheld, not reported as a problem.
5. Exactly one campaign record, naming the trusted plan digest
   (`campaign_missing`, `campaign_duplicate`, `plan_mismatch`).
6. Every attempt names the trusted plan digest and a job in it, and its task
   id and attempt id recompute (`plan_mismatch`, `job_not_in_plan`,
   `identity_mismatch`).
7. Every required job has exactly one disposition, and no disposition names a
   job outside the plan (`disposition_missing`, `disposition_duplicate`,
   `job_not_in_plan`).
8. Every attempt a disposition cites, as its supplying attempt or as an
   earlier attempt, is a member and belongs to that disposition's job and
   task. The disposition's state, reason and `budget_reached` equal the
   supplying attempt's `result`, `outcome_code` and `budget.reached`
   (`disposition_attempt_mismatch`).
9. Two attempt records with the same attempt id or the same attempt number
   for one task are a conflict that cannot be reconciled
   (`attempt_conflict`).
10. Every attempt member is cited by exactly one disposition, so membership
    and citations agree before anything is counted (`attempt_not_cited`). A
    record already reported in a conflict is not reported again here.
11. Each attempt's planned budget equals the trusted plan's budget for its
    job, and `budget.reached` is true exactly when `budget.used` is at least
    the planned budget (`budget_mismatch`). Two worker-supplied flags that
    agree with each other are not enough.
12. Every required control in the plan appears in each attempt's reported
    limits with a value at least as strict (`limit_not_demonstrated`). This
    check is consistency only: limits are worker claims.
13. When the trusted plan's profile mode is `mutate`, no artifact has public
    custody (`public_custody_in_mutate`), and the final corpus manifest is
    encrypted (`encryption_missing`).

The problem codes that come from record-collection/v0 keep its spelling.

Reporting rules, so that one fault yields one problem:

- A member that is unresolved, fails its digest or is not a valid record is
  reported once. Checks that need its content are skipped.
- A record that names a different plan is reported once as `plan_mismatch`.
  Its identities, citations, budget, limits and custody are not checked
  against the trusted plan.
- `body_not_encrypted` is reported once per body, against the first member
  that references it. `body_unreferenced` is a body that no member artifact
  references; the problem names it by its byte digest (`body`), carries no
  record id, and comes last within check 4, by digest.
- `public_custody_in_mutate` and `encryption_missing` are reported once per
  attempt record.
- Problems are listed in check order. Within one check they are sorted by job
  id, then record id; a campaign problem comes before attempt problems.
- `bodies_withheld` counts the distinct body digests referenced by member
  artifacts whose bytes are not in `bodies/`.

Completeness, for a valid bundle: a required job is complete when its
supplying attempt succeeded and its budget is reached by check 11, that is,
measured against the trusted plan.

What the observations contain, for a valid bundle:

- Findings from every cited attempt, including earlier attempts that were
  later retried. A finding is never dropped because its attempt was replaced.
  `finding_id` is unique only within its attempt, so every reported finding
  carries its `attempt_id`. Findings are listed by job id, then attempt
  number, then finding id.
- For each job, executions and the last coverage sample from the attempt that
  supplied its disposition, with that attempt's id and its reported subject
  binary digest, so every metric names the build that produced it. Jobs that
  never started are not listed.
- Every observation is labelled `basis: worker_claim`.

What a verified bundle establishes: the records are mutually consistent and
consistent with the plan the verifier trusts. Internal digest consistency
does not authenticate the collector: anyone who can write a bundle can write a
consistent one. It also does not establish that a particular host ran a
particular binary. Platform, limits, toolchain and binary digest are labelled
as worker claims in every report.

## Exit codes

The exit code reports the first fact that is not clean, in this order. The
codes come from the Fulmen exit-code catalog as supplied by gofulmen v0.3.6
(`foundry` package); the Go code uses those constants, never literals. Some
codes carry a narrower local meaning here, stated in the table:

| Order | Condition                     | Code                       | Local meaning                                                      |
| ----- | ----------------------------- | -------------------------- | ------------------------------------------------------------------ |
| 1     | Bundle invalid                | 63 `EXIT_DATA_CORRUPT`     | At least one validity problem                                      |
| 2     | Valid, at least one finding   | 91 `EXIT_TEST_FAILURE`     | An attempt reported a finding                                      |
| 3     | Valid, no finding, incomplete | 93 `EXIT_TEST_INTERRUPTED` | No finding, and at least one required job did not reach its budget |
| 4     | Valid, complete, no finding   | 0 `EXIT_SUCCESS`           |                                                                    |

`run` returns 24 `EXIT_ENVIRONMENT_INVALID` when the host cannot demonstrate a
required control, and writes a bundle whose jobs are all `not_started` with
reason `unsupported_host`. That bundle verifies as valid and incomplete (93).
A missing toolchain or engine is 21 `EXIT_MISSING_DEPENDENCY`, not 24.

The exit code is a summary for shells. Automation should read the verify
report (`--format json`), which states each fact separately, rather than infer
them from the code alone.

## Field mapping

Every field of the project file, plan, campaign and attempt documents, marked
with the contract it comes from or why it is local. Record contracts are pinned to
3leaps Crucible v0.2.14 and exit codes to gofulmen v0.3.6; the schemas used directly are copied unedited into
[`schemas/third_party/crucible/`](../../schemas/third_party/crucible/).

### Project file (`fuzzmuster.yaml`)

All local: the project file is product configuration, versioned with the tool.

| Field                               | Source                     | Notes                                               |
| ----------------------------------- | -------------------------- | --------------------------------------------------- |
| `version`                           | local                      | Project file format, `0`                            |
| `project`                           | local                      | Project name                                        |
| `targets[].name`                    | local                      | Target name, unique in the file                     |
| `targets[].adapter`                 | local                      | `cargo-fuzz` or `go-native`                         |
| `targets[].path`                    | local                      | Repository-relative directory of the fuzz package   |
| `targets[].entry`                   | local                      | cargo-fuzz target name or Go `Fuzz` function        |
| `targets[].seeds`                   | local                      | Repository-relative directory of reviewed seeds     |
| `profiles.<name>.mode`              | local                      | `replay` (never mutates) or `mutate`                |
| `profiles.<name>.targets`           | local                      | Optional subset of target names                     |
| `profiles.<name>.platform`          | local                      | Required `os` and `arch`                            |
| `profiles.<name>.toolchain`         | local                      | Required toolchain and sanitizer                    |
| `profiles.<name>.budget.per_target` | durable-runner/v0 duration | Grammar only                                        |
| `profiles.<name>.requires[]`        | local                      | Required controls; see the control vocabulary below |

Worker addresses, credentials and private storage locations never appear in
the project file. They belong to operator configuration.

### Plan

| Field                                                | Source                     | Notes                                                         |
| ---------------------------------------------------- | -------------------------- | ------------------------------------------------------------- |
| `v`, `kind`                                          | local                      | `0`, `fuzzmuster.plan`                                        |
| `project.name`                                       | local                      | From the project file                                         |
| `project.file_digest`                                | durable-record/v1 digest   | Byte digest of the project file                               |
| `source.vcs`, `source.revision`                      | local                      | Subject revision; no contract carries a VCS pin               |
| `profile.name`, `profile.mode`                       | local                      |                                                               |
| `platform.os`, `platform.arch`                       | local                      |                                                               |
| `platform.image_digest`                              | durable-record/v1 digest   | Optional; the platform-specific OCI image digest              |
| `toolchain.*`                                        | local                      | Adapter, adapter version, engine, toolchain, sanitizer        |
| `required_controls[]`                                | local                      | Required controls with their values                           |
| `budget.per_job`, `budget.total`                     | durable-runner/v0 duration | Grammar only                                                  |
| `jobs[].job_id`                                      | local                      | Becomes the durable-runner invocation key                     |
| `jobs[].target`, `jobs[].entry`                      | local                      |                                                               |
| `jobs[].required`                                    | local                      | A required job without a disposition makes the bundle invalid |
| `jobs[].budget`                                      | durable-runner/v0 duration | Grammar only                                                  |
| `jobs[].seeds.manifest_digest`, `jobs[].seeds.count` | durable-record/v1 digest   | Document digest of the seed manifest; see below               |

A plan is not a durable-runner task definition: it has no task-kind pin,
outcome mapping or retry policy, so `task_spec_digest` is not used. The plan
digest takes its place as the authority namespace of the task id, and the
plan digest is never called a `task_spec_digest`. The use case is sent to the
durable-runner owner as feedback.

### Campaign payload (`contract: fuzzmuster-campaign/v0`)

| Field                                                                                                                              | Source                                                 | Notes                                                                                                                       |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Envelope (`v`, `stream`, `record_id`, `revision`, `supersedes`, `payload_contract`, `provenance`, `produced_at`, `classification`) | durable-record/v1 record                               | Unchanged meaning                                                                                                           |
| `v`                                                                                                                                | local                                                  | Payload version `0`                                                                                                         |
| `plan_digest`                                                                                                                      | durable-record/v1 digest                               | Must equal the trusted plan's digest                                                                                        |
| `host_check.status`                                                                                                                | local                                                  | `supported` or `unsupported`                                                                                                |
| `host_check.missing[]`                                                                                                             | local                                                  | Required controls the host could not demonstrate                                                                            |
| `jobs[].job_id`                                                                                                                    | local                                                  |                                                                                                                             |
| `jobs[].task_id`                                                                                                                   | durable-runner/v0 task identity                        | Recomputed by `verify`                                                                                                      |
| `jobs[].state`                                                                                                                     | durable-runner/v0 attempt `result`, plus `not_started` | `succeeded`, `failed`, `cancelled`, `abandoned`; `not_started` is local because a task that never ran has no attempt result |
| `jobs[].reason`                                                                                                                    | durable-runner/v0 `outcome_code` grammar               | Local vocabulary, for example `budget_reached`, `finding_stop`, `host_lost`, `unsupported_host`                             |
| `jobs[].budget_reached`                                                                                                            | local                                                  | Collector's copy of the attempt flag; `verify` recomputes completeness from the trusted plan                                |
| `jobs[].attempt`                                                                                                                   | durable-record/v1 pin                                  | The attempt that supplied the disposition                                                                                   |
| `jobs[].earlier_attempts[]`                                                                                                        | durable-record/v1 pin                                  | Retained earlier attempts                                                                                                   |

### Attempt payload (`contract: fuzzmuster-attempt/v0`)

| Field                                  | Source                                   | Notes                                                                                                                                                      |
| -------------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Envelope                               | durable-record/v1 record                 | Revision 1 only                                                                                                                                            |
| `v`                                    | local                                    | Payload version `0`                                                                                                                                        |
| `plan_digest`                          | durable-record/v1 digest                 |                                                                                                                                                            |
| `job_id`                               | local                                    |                                                                                                                                                            |
| `task_id`, `attempt_n`, `attempt_id`   | durable-runner/v0 identities             | Recomputed by `verify`                                                                                                                                     |
| `result`                               | durable-runner/v0 attempt `result`       | `succeeded`, `failed`, `cancelled`, `abandoned`                                                                                                            |
| `outcome_code`                         | durable-runner/v0 `outcome_code` grammar | Local vocabulary                                                                                                                                           |
| `budget.planned`, `budget.used`        | durable-runner/v0 duration               | Grammar only                                                                                                                                               |
| `budget.reached`                       | local                                    |                                                                                                                                                            |
| `worker_claims.platform`               | local                                    | Reported by the worker; labelled as a claim                                                                                                                |
| `worker_claims.subject_binary`         | durable-record/v1 digest                 | Byte digest of the fuzz binary; a claim                                                                                                                    |
| `worker_claims.toolchain`              | local                                    | A claim                                                                                                                                                    |
| `worker_claims.limits[]`               | local                                    | Control, value, `enforced_by`; a claim                                                                                                                     |
| `worker_claims.started_at`, `ended_at` | durable-record/v1 instant                | A claim, like `produced_at`                                                                                                                                |
| `observations.executions`              | local                                    | Engine-reported count                                                                                                                                      |
| `observations.coverage[]`              | local                                    | `engine`, `unit`, `at` (elapsed duration), `value`. Engine coverage stays local; coverage-attestation/v0 is a proposed external assessment and is not used |
| `observations.corpus`                  | durable-record/v1 `bodyRef`              | Final corpus manifest, by digest only; encrypted in a `mutate` profile                                                                                     |
| `observations.findings[]`              | local, with durable-record/v1 `bodyRef`  | See below                                                                                                                                                  |
| `artifacts[]`                          | durable-record/v1 `bodyRef`              | `role` and `custody` are local; finding roles are encrypted                                                                                                |

### Findings

| Field        | Source                                 | Notes                                                                                                                                    |
| ------------ | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `finding_id` | local                                  | Unique within the attempt                                                                                                                |
| `kind`       | local                                  | `crash`, `timeout`, `out_of_memory`, `leak`, `slow_input`                                                                                |
| `input`      | durable-record/v1 `bodyRef`, encrypted | Digest, length and media type of the ciphertext. The plaintext is never in a bundle; a body bundled for this reference is the ciphertext |
| `minimized`  | durable-record/v1 `bodyRef`, encrypted | Optional                                                                                                                                 |
| `first_seen` | durable-runner/v0 duration             | Elapsed time into the attempt                                                                                                            |

A finding never carries the input, a dump, a stack trace or a log excerpt.
Public output (a replay failure in public CI) names the target and the
finding kind only.

### Not used in v0

| Contract                             | Why                                                                                                                       |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| durable-runner/v0 transition records | v0 records the attempt result, not the transition history. A runner that keeps transitions can add them as members later  |
| durable-runner/v0 task definition    | See the plan section above                                                                                                |
| process-run/v0                       | Live progress is optional and not part of a result                                                                        |
| data-acquisition/v0                  | Seeds are local and pinned by content manifest; data-acquisition applies when a corpus is acquired from a governed source |
| coverage-attestation/v0              | Proposed, not ratified                                                                                                    |

## Control vocabulary

| Control                    | Value       | Meaning                                                                                                                       |
| -------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `engine_input_timeout`     | `duration`  | The engine aborts an input that runs longer (libFuzzer `-timeout`)                                                            |
| `engine_rss_limit`         | `mebibytes` | The engine aborts when resident memory exceeds the limit (libFuzzer `-rss_limit_mb`)                                          |
| `memory_ceiling`           | `mebibytes` | A hard ceiling enforced when an allocation happens: a container or VM memory controller with swap off, one worker per ceiling |
| `worker_deadline_kill`     | `duration`  | At the deadline the worker is killed from outside the call, and the in-flight input is kept                                   |
| `outputs_outside_worktree` | none        | Corpus, cache and findings are written outside the source checkout                                                            |

A required control is either demonstrated on the host or the run does not
start. `enforced_by` in an attempt records what enforced each control:
`engine`, `kernel`, `vm` or `supervisor`.

## Seed manifest

A seed directory is pinned by the document digest of its manifest
([`seed-manifest.schema.json`](../../schemas/fuzzmuster/v0/seed-manifest.schema.json)):

```json
{ "v": 0, "entries": [{ "path": "a.txt", "digest": "sha256:…", "length": 12 }] }
```

Entries are sorted by `path` (a forward-slash path relative to the seed
directory). Only regular files are included.
