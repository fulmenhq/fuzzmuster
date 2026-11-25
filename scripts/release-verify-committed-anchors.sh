#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Ported from github.com/3leaps/docpresser scripts/release-verify-committed-anchors.sh at 21e0cad.
# Verify the committed public pin against both fingerprint anchors with the
# designated checker. In-tree material only; no maintainer env vars.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-decernor.sh
source "$root/scripts/release-decernor.sh"
# Before the one-time pin export none of the trust files exist; say so
# plainly. A partial set falls through to the checks below and fails there.
present=0
for path in docs/security/release-signing-keys.asc keys/expected-fingerprints.txt keys/expected-fingerprints.ndjson; do
    [[ ! -e "$path" && ! -L "$path" ]] || present=1
done
[[ "$present" == 1 ]] || {
    echo 'error: no release signing pin is committed yet; see Public Pin Maintenance in RELEASE_CHECKLIST.md' >&2
    exit 1
}
resolve_release_decernor ceremony || {
    echo 'error: trusted Decernor identity/version check failed' >&2
    exit 1
}
release_verify_gpg_anchors keys/expected-fingerprints.txt keys/expected-fingerprints.ndjson \
    docs/security/release-signing-keys.asc || {
    echo 'error: committed public pin does not match the fingerprint anchors' >&2
    exit 1
}
echo '[ok] committed public pin matches both fingerprint anchors'
