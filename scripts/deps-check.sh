#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Dependency rule for the shipped binary and library:
#   1. no cgo: no Go file imports "C", under any build tag;
#   2. every module in the build graph of every supported platform is listed,
#      with its licence, in config/dependencies.txt.
# Usage: deps-check.sh [ROOT]
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$root"
GO="${GO:-go}"
fail=0

# 1. cgo. Match a single import "C" or one inside an import block.
while IFS= read -r -d '' f; do
    if awk '
		/^[[:space:]]*import[[:space:]]+"C"/ { found = 1 }
		/^[[:space:]]*import[[:space:]]*\(/ { block = 1; next }
		block && /^[[:space:]]*\)/ { block = 0 }
		block && /^[[:space:]]*"C"[[:space:]]*(\/\/.*)?$/ { found = 1 }
		END { exit found ? 0 : 1 }
	' "$f"; then
        echo "error: $f imports \"C\"; cgo is not allowed" >&2
        fail=1
    fi
done < <(git ls-files -z --cached --others --exclude-standard -- '*.go')

# 2. Modules. Collect the build graph on each release platform.
allowed="$(awk '!/^#/ && NF { print $1 }' config/dependencies.txt | sort -u)"
platforms="linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64 windows/arm64"
used=""
for p in $platforms; do
    used+="$(GOOS="${p%/*}" GOARCH="${p#*/}" CGO_ENABLED=0 GOFLAGS=-mod=readonly \
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
