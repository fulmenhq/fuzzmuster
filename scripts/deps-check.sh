#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Dependency rule for the shipped binary and library:
#   1. no cgo: no Go file imports "C", in any form or under any build tag;
#   2. no replace directive in go.mod;
#   3. every module in the build graph of every supported platform is listed,
#      with its licence, in config/dependencies.txt.
# Usage: deps-check.sh [ROOT]
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$root"
GO="${GO:-go}"
fail=0

# 1. cgo. Parse the imports of every tracked Go file, whatever its build
#    constraints (go list would skip cgo files under CGO_ENABLED=0).
gatecheck="$(mktemp -d)/gatecheck$("$GO" env GOEXE)"
trap 'rm -rf "$(dirname "$gatecheck")"' EXIT
CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off "$GO" build -o "$gatecheck" ./tools/gatecheck
go_files=()
while IFS= read -r -d '' f; do go_files+=("$f"); done < <(git ls-files -z --cached --others --exclude-standard -- '*.go')
"$gatecheck" cgo "${go_files[@]}" || fail=1

# 2. No replace directives: a replace builds other code under a listed path.
GOWORK=off "$GO" mod edit -json | "$gatecheck" replace || fail=1

# 3. Modules. Collect the build graph on each release platform.
allowed="$(awk '!/^#/ && NF { print $1 }' config/dependencies.txt | sort -u)"
platforms="linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64 windows/arm64"
used=""
for p in $platforms; do
    used+="$(GOOS="${p%/*}" GOARCH="${p#*/}" CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
        "$GO" list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}{{end}}{{end}}' ./cmd/... ./internal/...)"$'\n'
done
used="$(printf '%s\n' "$used" | awk 'NF' | sort -u)"
while IFS= read -r m; do
    [ -n "$m" ] || continue
    if ! grep -qxF "$m" <<< "$allowed"; then
        echo "error: module $m is in the build graph but not in config/dependencies.txt" >&2
        fail=1
    fi
done <<< "$used"
while IFS= read -r m; do
    [ -n "$m" ] || continue
    if ! grep -qxF "$m" <<< "$used"; then
        echo "error: config/dependencies.txt lists $m, which no platform builds; remove it" >&2
        fail=1
    fi
done <<< "$allowed"

[ "$fail" -eq 0 ] || exit 1
echo "[ok] deps-check: no cgo; $(grep -c . <<< "$used") module(s), all listed"
