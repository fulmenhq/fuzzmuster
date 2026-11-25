#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Ported from github.com/3leaps/docpresser scripts/release-verify-committed-anchors.test.sh at 21e0cad.
# In-tree anchor verification: no maintainer env vars; any mismatch between the
# committed public pin and either anchor fails closed. Mutations run on a
# scratch copy, never on this checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="${FUZZMUSTER_DECERNOR_BIN:-$(command -v decernor || true)}"
[[ -n "$bin" && -x "$bin" ]] || {
    echo 'error: FUZZMUSTER_DECERNOR_BIN required (absolute path to decernor >= 0.1.8)' >&2
    exit 1
}
export FUZZMUSTER_DECERNOR_BIN="$bin"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
trap 'gpgconf --homedir "$scratch/gpg" --kill all > /dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/scripts" "$repo/keys" "$repo/docs/security"
cp "$root/scripts/release-verify-committed-anchors.sh" "$root/scripts/release-decernor.sh" "$repo/scripts/"
# No real pin is read: a throwaway primary and signing subkey stand in for it,
# and the anchors are derived from that public export.
mkdir -m 700 "$scratch/gpg"
gpg --homedir "$scratch/gpg" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
    'Release Fixture <release-fixture@example.invalid>' ed25519 cert 0 > /dev/null 2>&1
primary="$(gpg --homedir "$scratch/gpg" --batch --with-colons --fingerprint --list-keys 2> /dev/null | awk -F: '$1=="fpr" {print $10;exit}')"
gpg --homedir "$scratch/gpg" --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$primary" ed25519 sign 1d > /dev/null 2>&1
gpg --homedir "$scratch/gpg" --batch --armor --export "$primary" > "$repo/docs/security/release-signing-keys.asc" 2> /dev/null
"$bin" fingerprint "$repo/docs/security/release-signing-keys.asc" --class public --kind gpg \
    --format ndjson --path-mode none --gpg-role primary > "$repo/keys/expected-fingerprints.ndjson"
printf 'gpg %s\n' "$primary" > "$repo/keys/expected-fingerprints.txt"
# With no pin at all the check says so instead of naming one missing file.
mkdir -p "$scratch/nopin/scripts"
cp "$repo/scripts/"* "$scratch/nopin/scripts/"
if "$scratch/nopin/scripts/release-verify-committed-anchors.sh" > "$scratch/out" 2>&1; then
    echo 'error: accepted a checkout with no pin' >&2
    exit 1
fi
grep -qF 'no release signing pin is committed yet' "$scratch/out" || {
    echo 'error: no-pin checkout refused for the wrong reason' >&2
    cat "$scratch/out" >&2
    exit 1
}
cp -R "$repo/keys" "$scratch/good-keys"
check() {
    env -u FUZZMUSTER_PGP_KEY_ID -u FUZZMUSTER_GPG_SIGNING_FINGERPRINT -u FUZZMUSTER_GPG_HOMEDIR \
        "$repo/scripts/release-verify-committed-anchors.sh"
}
refused() {
    local why="$1" expected="$2"
    if check > "$scratch/out" 2>&1; then
        echo "error: accepted: $why" >&2
        exit 1
    fi
    grep -qF -- "$expected" "$scratch/out" || {
        echo "error: rejected for the wrong reason: $why" >&2
        cat "$scratch/out" >&2
        exit 1
    }
    rm -rf "$repo/keys"
    cp -R "$scratch/good-keys" "$repo/keys"
    echo "[ok] refused: $why"
}
# The committed material verifies without the maintainer-only variables.
check > /dev/null
# The checker is required.
if env -u FUZZMUSTER_DECERNOR_BIN "$repo/scripts/release-verify-committed-anchors.sh" > /dev/null 2>&1; then
    echo 'error: verification ran without FUZZMUSTER_DECERNOR_BIN' >&2
    exit 1
fi
printf 'gpg %040d\n' 0 > "$repo/keys/expected-fingerprints.txt"
refused 'text anchor for another primary' 'text fingerprint anchor differs'
printf '%s\nminisign %064d\n' "$(cat "$scratch/good-keys/expected-fingerprints.txt")" 0 > "$repo/keys/expected-fingerprints.txt"
refused 'extra text anchor line' 'text fingerprint anchor differs'
sed 's/"key_role":"primary"/"key_role":"subkey"/' "$scratch/good-keys/expected-fingerprints.ndjson" > "$repo/keys/expected-fingerprints.ndjson"
refused 'mutated NDJSON anchor' 'NDJSON fingerprint anchor differs'
cat "$scratch/good-keys/expected-fingerprints.ndjson" "$scratch/good-keys/expected-fingerprints.ndjson" > "$repo/keys/expected-fingerprints.ndjson"
refused 'duplicated NDJSON anchor' 'NDJSON fingerprint anchor differs'
rm "$repo/keys/expected-fingerprints.ndjson"
refused 'missing NDJSON anchor' 'missing or not a nonempty regular file'
ln -s "$scratch/good-keys/expected-fingerprints.txt" "$repo/keys/expected-fingerprints.txt.link"
rm "$repo/keys/expected-fingerprints.txt"
mv "$repo/keys/expected-fingerprints.txt.link" "$repo/keys/expected-fingerprints.txt"
refused 'symlinked text anchor' 'missing or not a nonempty regular file'
check > /dev/null
echo '[ok] committed-anchor verification uses only in-tree material'
