# toyparse (synthetic example)

A small, synthetic Rust parser used as the fuzzmuster example subject. It is
not a real library and is never published.

- `src/lib.rs`: parses `key=value;key=value` records and newline-separated
  streams, and renders a record back to text.
- `fuzz/`: three cargo-fuzz targets (`parse_record`, `parse_stream`,
  `render_record`).
- `fuzz/seeds/`: reviewed seed inputs, one directory per target. These are
  the only inputs the `public` profile replays.
- `fuzzmuster.yaml`: the project file.

The fuzz crate in `fuzz/` is not built or checked by this repository's CI.
Before anything builds it, its `Cargo.lock` is committed, `libfuzzer-sys` is
pinned exactly, and its dependency closure is listed with licences like the
Go closure.

The result fixtures under `testdata/fixtures/v0/` describe campaigns over this
project. They are hand-written examples, not records of real runs.
