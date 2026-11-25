#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Origin: the Fulmen Go microtool template (scripts/verify-public-key.sh);
# rewritten to validate the whole file.
#
# verify-public-key.sh KEY_FILE
#
# Accept KEY_FILE only if it is exactly one ASCII-armored OpenPGP public key
# block, with nothing but whitespace around it, and GnuPG finds public key
# packets and no secret key packet anywhere in it. Anything else, including
# trailing data after the armor, any non-ASCII byte, or a missing gpg, is
# refused. Exit 0 means safe to publish; any other exit means do not.
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
[[ -f "$key" && ! -L "$key" ]] || die "$key is not a regular file"
command -v gpg > /dev/null 2>&1 || die 'gpg is required to verify the key file'

# 1. Structure: printable ASCII and whitespace only; one public key block;
#    nothing outside it but whitespace.
"${PYTHON:-python3}" -I -B - "$key" << 'PY' || die "$key is not exactly one armored public key block"
import re, sys
data = open(sys.argv[1], "rb").read()
if any(b > 0x7E or (b < 0x20 and b not in (0x09, 0x0A, 0x0D)) for b in data):
    sys.exit("non-ASCII or control bytes present")
text = data.decode("ascii")
begin = "-----BEGIN PGP PUBLIC KEY BLOCK-----"
end = "-----END PGP PUBLIC KEY BLOCK-----"
if text.count("-----BEGIN ") != 1 or text.count("-----END ") != 1:
    sys.exit("expected exactly one armor block")
m = re.fullmatch(r"\s*" + re.escape(begin) + r"\r?\n.*?\r?\n" + re.escape(end) + r"\s*", text, re.S)
if not m:
    sys.exit("content outside the public key block")
PY

# 2. Packets, in an isolated empty keyring: public keys present, no secret
#    key or secret subkey packet.
home="$(mktemp -d)"
trap 'gpgconf --homedir "$home" --kill all > /dev/null 2>&1 || true; rm -rf "$home"' EXIT
chmod 700 "$home"
packets="$(gpg --homedir "$home" --batch --list-packets "$key" 2>&1)" || die 'gpg could not parse the key file'
if grep -Eq ':secret (sub )?key packet:' <<< "$packets"; then
    die "$key contains secret key material"
fi
grep -Eq ':public key packet:' <<< "$packets" || die "$key contains no public key packet"
listing="$(gpg --homedir "$home" --batch --with-colons --import-options show-only --import "$key" 2>&1)" ||
    die 'gpg could not read the key file'
if grep -Eq '^(sec|ssb):' <<< "$listing"; then
    die "$key contains secret key material"
fi
grep -Eq '^pub:' <<< "$listing" || die "$key holds no public key"

echo "[ok] $key: one armored public key block, no secret key material"
