#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Origin: the Fulmen Go microtool template (scripts/verify-public-key.sh);
# rewritten to validate the whole file.
#
# verify-public-key.sh KEY_FILE
#
# Accept KEY_FILE only if it is exactly one canonically armored OpenPGP
# public key block, with nothing but whitespace around it, whose packets are
# all public-key packet types, and GnuPG agrees there is no secret key. Anything else, including
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

# 1. Structure and content, independent of GnuPG: printable ASCII only; one
#    public key block in canonical armor (headers, blank line, base64 body,
#    optional CRC24 that must match, END), nothing outside it but whitespace;
#    the decoded body must parse exactly, end to end, into an allowlist of
#    packet types: public key (6), public subkey (14), user ID (13),
#    signature (2) and marker (10), starting with a public key.
"${PYTHON:-python3}" -I -B - "$key" << 'PY' || die "$key is not exactly one armored public key with allowed packets"
import base64, binascii, re, sys

data = open(sys.argv[1], "rb").read()
if any(b > 0x7E or (b < 0x20 and b not in (0x09, 0x0A, 0x0D)) for b in data):
    sys.exit("non-ASCII or control bytes present")
lines = data.decode("ascii").replace("\r\n", "\n").split("\n")
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()
if not lines or lines[0] != "-----BEGIN PGP PUBLIC KEY BLOCK-----" or lines[-1] != "-----END PGP PUBLIC KEY BLOCK-----":
    sys.exit("not a single public key block")
body = lines[1:-1]
# Armor headers (Key: Value) end at the first blank line.
i = 0
while i < len(body) and body[i] != "":
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*: .*", body[i]):
        sys.exit("malformed armor header")
    i += 1
if i == len(body):
    sys.exit("missing blank line after armor headers")
payload = body[i + 1:]
crc = None
if payload and payload[-1].startswith("="):
    crc = payload.pop()
for line in payload:
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", line):
        sys.exit("non-base64 line in armor body")
try:
    raw = base64.b64decode("".join(payload), validate=True)
except binascii.Error:
    sys.exit("invalid base64")
if base64.b64encode(raw).decode() != "".join(payload):
    sys.exit("non-canonical base64")


def crc24(buf):
    c = 0xB704CE
    for b in buf:
        c ^= b << 16
        for _ in range(8):
            c <<= 1
            if c & 0x1000000:
                c ^= 0x1864CFB
    return c & 0xFFFFFF


if crc is not None:
    if not re.fullmatch(r"=[A-Za-z0-9+/]{4}", crc) or base64.b64decode(crc[1:]) != crc24(raw).to_bytes(3, "big"):
        sys.exit("armor checksum mismatch")

ALLOWED = {2, 6, 10, 13, 14}
pos, tags = 0, []
while pos < len(raw):
    ctb = raw[pos]
    pos += 1
    if not ctb & 0x80:
        sys.exit("invalid packet header")
    if ctb & 0x40:  # new format
        tag = ctb & 0x3F
        if pos >= len(raw):
            sys.exit("truncated packet")
        o1 = raw[pos]
        if o1 < 192:
            length, pos = o1, pos + 1
        elif o1 < 224:
            if pos + 1 >= len(raw):
                sys.exit("truncated packet")
            length, pos = ((o1 - 192) << 8) + raw[pos + 1] + 192, pos + 2
        elif o1 == 255:
            if pos + 4 >= len(raw):
                sys.exit("truncated packet")
            length, pos = int.from_bytes(raw[pos + 1:pos + 5], "big"), pos + 5
        else:
            sys.exit("partial body lengths are not allowed in a key")
    else:  # old format
        tag, ltype = (ctb >> 2) & 0x0F, ctb & 0x03
        if ltype == 3:
            sys.exit("indeterminate packet length")
        n = (1, 2, 4)[ltype]
        if pos + n > len(raw):
            sys.exit("truncated packet")
        length, pos = int.from_bytes(raw[pos:pos + n], "big"), pos + n
    if pos + length > len(raw):
        sys.exit("truncated packet")
    if tag not in ALLOWED:
        sys.exit(f"packet type {tag} is not allowed in a public key file")
    tags.append(tag)
    pos += length
if not tags or tags[0] != 6:
    sys.exit("the file does not start with a public key packet")
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
