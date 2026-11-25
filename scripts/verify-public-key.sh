#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Origin: the Fulmen Go microtool template (scripts/verify-public-key.sh);
# rewritten to validate the whole file structurally.
#
# verify-public-key.sh KEY_FILE
#
# Refuse KEY_FILE unless it is one canonically armored OpenPGP public key
# with every byte accounted for (scripts/pubkey-check.py), GnuPG finds no
# secret key material in it, and it is byte for byte GnuPG's own export of
# the public keys it imports. A missing gpg or python3 is a refusal. Exit 0
# means safe to publish; any other exit means do not.
#
# Threat model and its limits: see scripts/pubkey-check.py.
set -euo pipefail

die() {
    echo "error: $*" >&2
    echo "DO NOT PUBLISH this file." >&2
    exit 1
}

[[ $# -eq 1 ]] || {
    echo "usage: $0 KEY_FILE" >&2
    exit 2
}
key="$1"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ -f "$key" && ! -L "$key" ]] || die "$key is not a regular file"
command -v gpg > /dev/null 2>&1 || die 'gpg is required to verify the key file'
command -v "${PYTHON:-python3}" > /dev/null 2>&1 || die 'python3 is required to verify the key file'

# 1. Structure, from the raw bytes: armor, packets, key material, signature
#    subpackets and user IDs, each consumed exactly.
"${PYTHON:-python3}" -I -B "$root/scripts/pubkey-check.py" "$key" || die "$key failed the structural check"

# 2. GnuPG, in an isolated empty keyring: no secret key or secret subkey
#    packet, public keys present, nothing secret after import.
home="$(mktemp -d)"
trap 'gpgconf --homedir "$home" --kill all > /dev/null 2>&1 || true; rm -rf "$home"' EXIT
chmod 700 "$home"
packets="$(gpg --homedir "$home" --batch --list-packets "$key" 2>&1)" || die 'gpg could not parse the key file'
if grep -Eq ':secret (sub )?key packet:' <<< "$packets"; then
    die "$key contains secret key material"
fi
listing="$(gpg --homedir "$home" --batch --with-colons --import-options show-only --import "$key" 2>&1)" ||
    die 'gpg could not read the key file'
if grep -Eq '^(sec|ssb):' <<< "$listing"; then
    die "$key contains secret key material"
fi
grep -Eq '^pub:' <<< "$listing" || die "$key holds no public key"
gpg --homedir "$home" --batch --quiet --import "$key" > /dev/null 2>&1 || die 'gpg could not import the key file'
if gpg --homedir "$home" --batch --list-secret-keys --with-colons 2> /dev/null | grep -q '^sec:'; then
    die "$key imported secret key material"
fi

# 3. Round trip: the decoded file must equal GnuPG's export of what it
#    imported, so GnuPG keeps every byte of it.
gpg --homedir "$home" --batch --dearmor -o "$home/input.bin" < "$key" 2> /dev/null || die 'gpg could not dearmor the key file'
gpg --homedir "$home" --batch --export -o "$home/export.bin" 2> /dev/null || die 'gpg could not re-export the key'
cmp -s "$home/input.bin" "$home/export.bin" ||
    die "$key differs from GnuPG's own export of its keys"

echo "[ok] $key: one armored public key, no secret key material"
