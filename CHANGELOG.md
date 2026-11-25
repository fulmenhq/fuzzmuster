# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Go module and `fuzzmuster` binary on the Fulmen microtool structure.
- `version` with `--extended` and `--format json`
  (`schemas/fuzzmuster/v0/version.schema.json`), `envinfo`, and `doctor`
  (installation checks only).
- Exit codes from the Fulmen catalog, with `64` for usage errors.
- Checks: no cgo and a hand-listed dependency closure (`make deps-check`),
  committed-content check, standalone smoke run, CI on Linux (x86_64,
  aarch64), macOS (arm64) and Windows (x86_64, aarch64).

[Unreleased]: https://github.com/fulmenhq/fuzzmuster/commits/main
