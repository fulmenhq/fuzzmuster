#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Controls for package-artifacts.sh signing: SIGN=1 fails closed without gpg,
# without an explicit FUZZMUSTER_RELEASE_TAG, and without a committed signing
# pin; an unknown SIGN value is refused; and none of these leaves a
# SHA256SUMS.asc behind. Unsigned packaging still succeeds. Runs on a scratch
# copy with stand-in binaries; no keys, no network.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo"
(cd "$root" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$repo"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
version="$(tr -d ' \t\r\n' < "$repo/VERSION")"
mkdir -p "$repo/bin"
for p in linux-amd64 linux-arm64 darwin-arm64; do printf 'stand-in\n' > "$repo/bin/fuzzmuster-$p"; done
for p in windows-amd64 windows-arm64; do printf 'stand-in\n' > "$repo/bin/fuzzmuster-$p.exe"; done

run() { (cd "$repo" && rm -rf dist && env -u FUZZMUSTER_RELEASE_TAG "$@" scripts/package-artifacts.sh) > "$scratch/out" 2>&1; }
refuse() {
    local why="$1" want="$2"
    shift 2
    if run "$@"; then
        echo "error: accepted: $why" >&2
        exit 1
    fi
    grep -q -- "$want" "$scratch/out" || {
        echo "error: $why refused for another reason" >&2
        cat "$scratch/out" >&2
        exit 1
    }
    [[ ! -e "$repo/dist/release/SHA256SUMS.asc" ]] || {
        echo "error: $why left a signature behind" >&2
        exit 1
    }
}

run env SIGN=0 || {
    cat "$scratch/out" >&2
    echo 'error: unsigned packaging failed' >&2
    exit 1
}
[[ -s "$repo/dist/release/SHA256SUMS" && ! -e "$repo/dist/release/SHA256SUMS.asc" ]]

mkdir "$scratch/nogpg"
for tool in bash env sh cat cp mkdir mktemp rm tr chmod ls tar zip python3 shasum sha256sum awk grep sed dirname basename git; do
    p="$(command -v "$tool" 2> /dev/null)" && ln -s "$p" "$scratch/nogpg/$tool"
done
refuse 'SIGN=1 without gpg' 'requires gpg' env PATH="$scratch/nogpg" SIGN=1 FUZZMUSTER_RELEASE_TAG="v$version"
refuse 'SIGN=1 without a release tag' 'FUZZMUSTER_RELEASE_TAG' env SIGN=1
refuse 'SIGN=1 without a committed pin' 'release signing pin\|signing-subkey\|fingerprint\|Decernor\|anchors' \
    env SIGN=1 FUZZMUSTER_RELEASE_TAG="v$version"
refuse 'unknown SIGN value' 'SIGN must be 0 or 1' env SIGN=yes

echo "[ok] package-artifacts signing controls"
