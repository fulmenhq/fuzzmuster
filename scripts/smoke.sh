#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Smoke-test a built fuzzmuster binary outside the repository with a clean
# environment: data on stdout, diagnostics on stderr, the documented exit
# codes, and version output that matches the build.
# Usage: smoke.sh BINARY VERSION COMMIT
set -euo pipefail
bin="$1" version="$2" commit="$3"
name="$(basename "$bin")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/tmp"
cp "$bin" "$work/$name"
cd "$work"
clean() { env -i PATH="$PATH" HOME="$work/home" USERPROFILE="$work/home" TMPDIR="$work/tmp" TEMP="$work/tmp" TMP="$work/tmp" SYSTEMROOT="${SYSTEMROOT:-}" "./$name" "$@"; }
fail() {
    echo "smoke: $*" >&2
    exit 1
}

clean version > out 2> err || fail "version exited $?"
[ "$(tr -d '\r' < out)" = "fuzzmuster $version" ] || fail "version printed '$(cat out)'"
[ ! -s err ] || fail "version wrote to stderr: $(cat err)"

clean version --extended > out 2> err || fail "version --extended exited $?"
grep -q "^Commit:  *$commit" out || fail "version --extended does not report commit $commit"
grep -q "^cgo:  *no" out || fail "version --extended does not report cgo off"

clean version --format json --extended > out 2> err || fail "version --format json exited $?"
"${PYTHON:-python3}" -I -B - "$version" "$commit" out << 'PY' || fail "version JSON did not match"
import json, sys
version, commit, path = sys.argv[1:4]
doc = json.load(open(path, encoding="utf-8"))
assert doc["$schema"] == "https://schemas.fulmenhq.dev/fuzzmuster/v0/version.schema.json", doc["$schema"]
assert doc["name"] == "fuzzmuster" and doc["version"] == version and doc["extended"] is True, doc
assert doc["commit"] == commit and doc["cgo_enabled"] is False, doc
PY

clean --help > out 2> err || fail "--help exited $?"
grep -q "version" out || fail "--help does not list version"

for cmd in doctor envinfo; do
    clean "$cmd" > out 2> err || fail "$cmd exited $?"
    [ ! -s out ] || fail "$cmd wrote diagnostics to stdout"
done

status=0
clean nosuchcommand > out 2> err || status=$?
[ "$status" -eq 64 ] || fail "unknown command exited $status, want 64"
[ ! -s out ] || fail "unknown command wrote to stdout"

echo "[ok] smoke: $name $version"
