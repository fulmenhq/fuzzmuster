#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Negative controls for deps-check.sh: an import "C" (single, grouped and
# build-tagged), an unlisted module and a stale listing are each refused; the
# unmodified tree is accepted. Runs on a scratch copy; needs go and git.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fresh() {
    rm -rf "$scratch/repo"
    mkdir -p "$scratch/repo"
    (cd "$root" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$scratch/repo"
    git -C "$scratch/repo" init -q
    git -C "$scratch/repo" add -A
}
accept() { "$root/scripts/deps-check.sh" "$scratch/repo" > /dev/null 2> "$scratch/err" || {
    echo "error: refused the unmodified tree" >&2
    cat "$scratch/err" >&2
    exit 1
}; }
refuse() {
    local why="$1" want="$2"
    git -C "$scratch/repo" add -A
    if "$root/scripts/deps-check.sh" "$scratch/repo" > /dev/null 2> "$scratch/err"; then
        echo "error: accepted: $why" >&2
        exit 1
    fi
    grep -q -- "$want" "$scratch/err" || {
        echo "error: $why refused for another reason" >&2
        cat "$scratch/err" >&2
        exit 1
    }
}

fresh
accept

fresh
printf 'package buildinfo\n\nimport "C"\n' > "$scratch/repo/internal/buildinfo/zz_cgo.go"
refuse 'single import "C"' 'imports "C"'

fresh
printf 'package buildinfo\n\nimport (\n\t"fmt"\n\t"C"\n)\n\nvar _ = fmt.Sprint\n' > "$scratch/repo/internal/buildinfo/zz_cgo.go"
refuse 'grouped import "C"' 'imports "C"'

fresh
printf '//go:build fuzzmusternever\n\npackage buildinfo\n\nimport "C"\n' > "$scratch/repo/internal/buildinfo/zz_cgo.go"
refuse 'build-tagged import "C"' 'imports "C"'

for form in 'import /* comment */ "C"' 'import c "C"' 'import _ "C"' 'import . "C"' 'import ("fmt"; "C")' 'import ( "fmt"; c "C" )'; do
    fresh
    printf 'package buildinfo\n\n%s\n' "$form" > "$scratch/repo/internal/buildinfo/zz_cgo.go"
    refuse "cgo import form: $form" 'imports "C"'
done

fresh
printf '//go:build ignore\n\npackage buildinfo\n\nimport /* x */ "C"\n' > "$scratch/repo/internal/buildinfo/zz_cgo.go"
refuse 'ignored-build file importing "C"' 'imports "C"'

fresh
mkdir -p "$scratch/fork"
printf 'module github.com/spf13/pflag\n\ngo 1.21\n' > "$scratch/fork/go.mod"
(cd "$scratch/repo" && GOWORK=off "${GO:-go}" mod edit -replace "github.com/spf13/pflag=$scratch/fork")
refuse 'replace directive' 'replace directives are not allowed'

fresh
sed -i.bak '/spf13\/pflag/d' "$scratch/repo/config/dependencies.txt"
rm "$scratch/repo/config/dependencies.txt.bak"
refuse 'unlisted module' 'not in config/dependencies.txt'

fresh
printf 'example.com/stale  MIT  nothing\n' >> "$scratch/repo/config/dependencies.txt"
refuse 'stale listing' 'which no platform builds'

echo "[ok] deps-check controls"
