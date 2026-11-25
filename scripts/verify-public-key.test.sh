#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Controls for verify-public-key.sh with a throwaway key: a public export
# passes; an armored secret export, a public export followed by a binary or
# armored secret export, trailing junk, two public blocks and a missing gpg
# are each refused. Needs gpg and python3; makes no network calls.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
check="$root/scripts/verify-public-key.sh"
scratch="$(mktemp -d)"
home="$scratch/gnupg"
mkdir -m 700 "$home"
trap 'gpgconf --homedir "$home" --kill all > /dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
g() { gpg --homedir "$home" --batch --pinentry-mode loopback --passphrase '' "$@"; }
g --quick-gen-key 'Fixture <fixture@example.invalid>' ed25519 sign never > /dev/null 2>&1
fpr="$(g --with-colons --list-keys | awk -F: '$1=="fpr" {print $10; exit}')"
g --armor --export "$fpr" > "$scratch/pub.asc" 2> /dev/null
g --armor --export-secret-keys "$fpr" > "$scratch/sec.asc"
g --export-secret-subkeys "$fpr" > "$scratch/sec.bin" 2> /dev/null || g --export-secret-keys "$fpr" > "$scratch/sec.bin"

accept() {
    "$check" "$1" > /dev/null 2> "$scratch/err" || {
        echo "error: refused $1" >&2
        cat "$scratch/err" >&2
        exit 1
    }
}
refuse() {
    if "$@" > /dev/null 2> "$scratch/err"; then
        echo "error: accepted: $*" >&2
        exit 1
    fi
    grep -q 'DO NOT PUBLISH' "$scratch/err" || {
        echo "error: refused without the publish warning: $*" >&2
        cat "$scratch/err" >&2
        exit 1
    }
}

accept "$scratch/pub.asc"
refuse "$check" "$scratch/sec.asc"
cat "$scratch/pub.asc" "$scratch/sec.bin" > "$scratch/pub+bin.asc"
refuse "$check" "$scratch/pub+bin.asc"
cat "$scratch/pub.asc" "$scratch/sec.asc" > "$scratch/pub+sec.asc"
refuse "$check" "$scratch/pub+sec.asc"
cat "$scratch/pub.asc" "$scratch/pub.asc" > "$scratch/two.asc"
refuse "$check" "$scratch/two.asc"
{
    cat "$scratch/pub.asc"
    printf 'trailing text\n'
} > "$scratch/trail.asc"
refuse "$check" "$scratch/trail.asc"
: > "$scratch/empty.asc"
refuse "$check" "$scratch/empty.asc"
# gpg missing: a PATH with only python3 and core tools, no gpg.
mkdir "$scratch/nogpg"
for tool in python3 bash env mktemp chmod rm grep awk cat tr; do
    p="$(command -v "$tool")" && ln -s "$p" "$scratch/nogpg/$tool"
done
refuse env PATH="$scratch/nogpg" "$check" "$scratch/pub.asc"

echo "[ok] verify-public-key controls"
