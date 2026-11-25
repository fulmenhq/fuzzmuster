# fuzzmuster contributor agent guide

Read `README.md`, `CONTRIBUTING.md` and `MAINTAINERS.md` before changing
code. Read local guidance when present; it lives outside the working tree.

## Current phase

Experimental, no release. Implemented: `version` (`--extended`,
`--format json`), `envinfo`, `doctor` (installation checks only).

- Do not add placeholder commands, flags or fields that imply support which
  does not exist.
- Keep argument parsing, output formats and exit codes in `internal/cmd`.
  Data goes to stdout; diagnostics and logs go to stderr.
- Every reporting command offers `--format json`, described by a schema under
  `schemas/`. Tests check output against the committed schema.
- No cgo, no fuzzing engine as a module dependency, permissive licences only.
  A new module needs a line in `config/dependencies.txt`.
- Expected results in fixtures are written by hand, never captured from the
  implementation. Never change an expectation to make the implementation pass.
- Do not claim tests, platforms or engine combinations that were not run.
- `internal/assets/**` is generated: edit `.fulmen/app.yaml`, then run
  `make sync-embedded-identity`.

## Public content

Follow the [Sensitive Local Data Policy](https://github.com/3leaps/oss-policies/blob/dee9d320f5b7045a44c92b200cc1c92ca83ae843/SENSITIVE-LOCAL-DATA.md).
No crash inputs, corpora or records from private campaigns, ever, in any
path. Private inputs, planning, identifiers and operating notes stay outside
the working tree, including ignored paths. Treat commit messages, branches
and PR text as permanent public content: say what changed, briefly.

## Checks

Run `make check-platform` before committing (or `make check` with goneat
installed), `make prepush` before pushing and `make pr-final` before opening
or updating a PR.

Use the public attribution footer on commits and PR bodies:

```text
Role: <bare-role>
Co-authored-by: <model> <noreply@3leaps.net>
Committer-of-Record: @3leapsdave
```
