# fuzzmuster

Plan, run and verify fuzz campaigns over the native fuzzing engines your
project already uses.

**Lifecycle phase**: `experimental` · no release yet

## Status

This repository is at its first step. The binary builds and implements three
commands: `version` (with `--extended` and `--format json`), `envinfo` and
`doctor`. `doctor` checks only fuzzmuster's own installation; it does not yet
check fuzzing toolchains or host controls. Nothing below "What we are
building" is implemented yet.

## Why

Fuzzing finds crashes, hangs and wrong answers that ordinary tests miss, by
feeding a program large numbers of generated inputs. The engines are mature:
libFuzzer (through cargo-fuzz for Rust) and Go's built-in `go test -fuzz`.
What is often missing is the workflow around them: deciding what to run and
for how long, running it on a machine that can contain a runaway input,
keeping crash inputs private until they are fixed, and being able to say
afterwards exactly what ran and what was observed.

fuzzmuster aims to make that workflow smooth and repeatable, in the way
[goneat](https://github.com/fulmenhq/goneat) does for formatting, linting and
other checks. It drives the engines; it does not contain or replace one.

## What we are building

| Command (planned)   | What it gives a maintainer                                                                                                         |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `fuzzmuster init`   | A small, reviewable project file listing the discovered fuzz targets. Discovery suggests; the checked-in file decides.             |
| `fuzzmuster doctor` | The installed engines and toolchains, the controls this host can enforce, and a remedy for each missing requirement.               |
| `fuzzmuster plan`   | The exact targets, pins, required limits and budget before anything runs.                                                          |
| `fuzzmuster run`    | A bounded run that records the limits it actually enforced, or refuses to run when the host cannot enforce what the plan requires. |
| `fuzzmuster replay` | Deterministic replay of reviewed inputs with no mutation, safe on a contributor machine and in public CI.                          |
| `fuzzmuster verify` | An offline check of a saved result against a plan you trust: is it intact, is it complete, and what was observed.                  |

Design rules that hold from the first release:

- A result is a file. There is no server, daemon, dashboard or database.
- Public output names a target and a failure kind; it never prints a crash
  input, a dump or a stack trace by default.
- A run never quietly weakens a plan: if a required limit cannot be enforced
  on a host, the run reports an unsupported host instead.
- Reports describe bounded observations (build, budget, engine, coverage
  units). Finishing a budget is not a claim that no defects remain.
- The shipped binary and library are pure Go, built with cgo off, with
  permissively licensed dependencies listed in
  [config/dependencies.txt](config/dependencies.txt).

## Build

Requires Go 1.26.9 or newer and Make.

```sh
make build        # bin/fuzzmuster
make check-platform
bin/fuzzmuster version --extended
```

`make help` lists every target. `make bootstrap` installs
[goneat](https://github.com/fulmenhq/goneat) and the formatting and lint
tools that `make check` uses.

## Exit codes

Codes follow the Fulmen exit-code catalog. Today: `0` success, `1` failure,
`20` invalid configuration, `64` usage error (unknown command or flag, bad
flag value, unexpected argument). Each new command will document which of
its outcomes its exit code reports first.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
Never put a crash input or other material from a private fuzzing campaign in
a public issue or pull request.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE)
at your option. See [NOTICE](NOTICE).
