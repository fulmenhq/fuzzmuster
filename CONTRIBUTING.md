# Contributing

fuzzmuster is experimental; see the [README](README.md) for status. Useful
contributions now are questions about the planned workflow, descriptions of
how you run fuzzing today and what gets in the way, and small focused fixes.

## Ground rules

- Use public synthetic examples. Do not submit crash inputs, corpora or
  records from a private fuzzing campaign, private data, secrets or redacted
  production examples. Follow the
  [Sensitive Local Data Policy](https://github.com/3leaps/oss-policies/blob/dee9d320f5b7045a44c92b200cc1c92ca83ae843/SENSITIVE-LOCAL-DATA.md).
- The binary and library are pure Go with cgo off. No fuzzing engine is a Go
  module dependency; fuzzmuster starts the engine the user installed.
- A new module dependency needs a permissive licence and a line in
  [config/dependencies.txt](config/dependencies.txt); `make deps-check`
  refuses anything unlisted.
- Do not add a command, flag or document field that implies behaviour which
  does not exist.
- Proposed changes need maintainer review.

## Checks

Install Go 1.26.9 or newer, Make, Git and Python 3.11 or newer, then run:

```sh
make check-platform
```

This runs `gofmt` and `go vet`, the tests with cgo off, a smoke run of the
built binary outside the repository, the dependency rule, and the check of
committed files for local paths, keys and tokens.

`make check` is what the Linux CI cells run. It adds goneat's format and lint
gates and the dependency-rule controls; run `make bootstrap` first to install
goneat. Before pushing, run `make prepush`, which adds the race detector
(needs a C compiler), `actionlint` and the licence audit.

Change the version only through `make version-set V=X.Y.Z` or the
`make version-bump-*` targets; they keep `VERSION` and the app identity in
step.

## License

Contributions are licensed under MIT OR Apache-2.0. AI-assisted work is
welcome under human supervision and the attribution rules in
[AGENTS.md](AGENTS.md).
