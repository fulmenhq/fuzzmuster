#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Controls for verify-public-key.sh with a throwaway key: a public export
# (gpg's armor or a canonical re-armor) passes; an armored secret export, a
# public export followed by a binary or armored secret export, secret bytes
# carried inside one public block (as secret, literal-data or experimental
# packets, or appended inside a key, user ID or signature packet body), a
# free-form signature notation, a long user ID, extra data after the checksum, a wrong checksum, trailing junk,
# two public blocks and a missing gpg are each refused. Needs gpg and python3; makes no network calls.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
check="$root/scripts/verify-public-key.sh"
scratch="$(mktemp -d)"
home="$scratch/gnupg"
mkdir -m 700 "$home"
trap 'for h in "$home" "$scratch/gnupg2" "$scratch/gnupg3" "$scratch/gnupg4"; do gpgconf --homedir "$h" --kill all > /dev/null 2>&1 || true; done; rm -rf "$scratch"' EXIT
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
    grep -q "DO NOT PUBLISH" "$scratch/err" && { [[ -z "${WANT:-}" ]] || grep -q -- "$WANT" "$scratch/err"; } || {
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
# Re-armor helper: canonical armor (with a correct CRC24) around raw bytes.
armor() {
    "${PYTHON:-python3}" -I -B - "$@" << 'PY'
import base64, sys
raw = b"".join(open(f, "rb").read() for f in sys.argv[2:])
def crc24(buf):
    c = 0xB704CE
    for b in buf:
        c ^= b << 16
        for _ in range(8):
            c <<= 1
            if c & 0x1000000:
                c ^= 0x1864CFB
    return c & 0xFFFFFF
b64 = base64.b64encode(raw).decode()
body = "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
crc = base64.b64encode(crc24(raw).to_bytes(3, "big")).decode()
open(sys.argv[1], "w").write("-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n" + body + "\n=" + crc + "\n-----END PGP PUBLIC KEY BLOCK-----\n")
PY
}
# new-format packet: tag byte, 4-byte length, body
packet() {
    "${PYTHON:-python3}" -I -B -c 'import sys; t=int(sys.argv[1]); b=open(sys.argv[2],"rb").read(); sys.stdout.buffer.write(bytes([0xC0|t,255])+len(b).to_bytes(4,"big")+b)' "$1" "$2"
}
g --export "$fpr" > "$scratch/pub.bin" 2> /dev/null
armor "$scratch/rearmored.asc" "$scratch/pub.bin"
accept "$scratch/rearmored.asc"
packet 11 "$scratch/sec.bin" > "$scratch/literal.bin"
armor "$scratch/pub+literal.asc" "$scratch/pub.bin" "$scratch/literal.bin"
WANT="packet type 11" refuse "$check" "$scratch/pub+literal.asc"
packet 62 "$scratch/sec.bin" > "$scratch/exp.bin"
armor "$scratch/pub+exp.asc" "$scratch/pub.bin" "$scratch/exp.bin"
WANT="packet type 62" refuse "$check" "$scratch/pub+exp.asc"
armor "$scratch/pub+secpkt.asc" "$scratch/pub.bin" "$scratch/sec.bin"
WANT="packet type 5" refuse "$check" "$scratch/pub+secpkt.asc"
# extra base64 after the checksum line, and a wrong checksum
sed 's/^\(=.*\)$/\1\nQUFBQQ==/' "$scratch/rearmored.asc" > "$scratch/after-crc.asc"
refuse "$check" "$scratch/after-crc.asc"
sed 's/^=.*$/=AAAA/' "$scratch/rearmored.asc" > "$scratch/bad-crc.asc"
WANT="checksum" refuse "$check" "$scratch/bad-crc.asc"
# Secret bytes appended inside the body of an allowed packet (key, user ID,
# signature): GnuPG drops or rejects them, so the round trip refuses.
"${PYTHON:-python3}" -I -B - "$scratch" << 'PY'
import sys
S = sys.argv[1]
raw = open(f"{S}/pub.bin", "rb").read()
sec = open(f"{S}/sec.bin", "rb").read()
def packets(b):
    out, p = [], 0
    while p < len(b):
        c = b[p]; p += 1
        if c & 0x40:
            t, o = c & 0x3F, b[p]
            if o < 192: n, p = o, p + 1
            elif o < 224: n, p = ((o - 192) << 8) + b[p + 1] + 192, p + 2
            else: n, p = int.from_bytes(b[p + 1:p + 5], "big"), p + 5
        else:
            t, k = (c >> 2) & 15, (1, 2, 4)[c & 3]
            n, p = int.from_bytes(b[p:p + k], "big"), p + k
        out.append((t, b[p:p + n])); p += n
    return out
def enc(t, body): return bytes([0xC0 | t, 255]) + len(body).to_bytes(4, "big") + body
for victim in (6, 13, 2):
    out, done = b"", False
    for t, body in packets(raw):
        if t == victim and not done:
            body, done = body + sec, True
        out += enc(t, body)
    open(f"{S}/stuffed{victim}.bin", "wb").write(out)
PY
for victim in 6 13 2; do
    armor "$scratch/stuffed$victim.asc" "$scratch/stuffed$victim.bin"
    refuse "$check" "$scratch/stuffed$victim.asc"
done
# Free-form data in a signature notation, and a long user ID, each on a
# fresh throwaway key.
fresh_key() {
    local h="$1"
    mkdir -m 700 "$h"
    gpg --homedir "$h" --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key 'Fixture <fixture@example.invalid>' ed25519 sign never > /dev/null 2>&1
    gpg --homedir "$h" --with-colons --list-keys 2> /dev/null | awk -F: '$1=="fpr" {print $10; exit}'
}
h2="$scratch/gnupg2"
f2="$(fresh_key "$h2")"
gpg --homedir "$h2" --batch --pinentry-mode loopback --passphrase '' \
    --cert-notation 'data@example.invalid=QUFBQUFBQUFBQUFBQUFBQQ' --quick-add-uid "$f2" 'Second <second@example.invalid>' > /dev/null 2>&1
gpg --homedir "$h2" --armor --export "$f2" > "$scratch/notation.asc" 2> /dev/null
grep -q 'data@example.invalid' <(gpg --homedir "$h2" --list-packets "$scratch/notation.asc" 2> /dev/null) || {
    echo 'error: fixture did not produce a notation' >&2
    exit 1
}
WANT="notation" refuse "$check" "$scratch/notation.asc"
h3="$scratch/gnupg3"
f3="$(fresh_key "$h3")"
gpg --homedir "$h3" --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-uid "$f3" "Fixture $(printf 'A%.0s' $(seq 1 200)) <fixture@example.invalid>" > /dev/null 2>&1
gpg --homedir "$h3" --armor --export "$f3" > "$scratch/longuid.asc" 2> /dev/null
WANT="user ID" refuse "$check" "$scratch/longuid.asc"
# Armor headers (here carrying base64 of a secret export) are refused.
{
    echo '-----BEGIN PGP PUBLIC KEY BLOCK-----'
    base64 < "$scratch/sec.bin" | tr -d '\n' | fold -w 60 | sed 's/^/Comment: /'
    echo
    sed '1,/^$/d' "$scratch/rearmored.asc"
} > "$scratch/headers.asc"
WANT="armor headers" refuse "$check" "$scratch/headers.asc"
# A notation whose value imitates GnuPG's listing text is still a notation.
h4="$scratch/gnupg4"
f4="$(fresh_key "$h4")"
gpg --homedir "$h4" --batch --pinentry-mode loopback --passphrase '' \
    --cert-notation 'x@example.invalid=a subpkt 2 len 4 b' --quick-add-uid "$f4" 'Second <second@example.invalid>' > /dev/null 2>&1
gpg --homedir "$h4" --armor --export "$f4" > "$scratch/forged.asc" 2> /dev/null
WANT="notation" refuse "$check" "$scratch/forged.asc"
# A short user ID of non-printable bytes.
"${PYTHON:-python3}" -I -B - "$scratch" << 'PY'
import sys
S = sys.argv[1]
raw = open(f"{S}/pub.bin", "rb").read()
p, out = 0, b""
while p < len(raw):
    c = raw[p]
    t = c & 0x3F if c & 0x40 else (c >> 2) & 15
    if c & 0x40:
        o = raw[p + 1]
        if o < 192: n, h = o, 2
        elif o < 224: n, h = ((o - 192) << 8) + raw[p + 2] + 192, 3
        else: n, h = int.from_bytes(raw[p + 2:p + 6], "big"), 6
    else:
        k = (1, 2, 4)[c & 3]
        n, h = int.from_bytes(raw[p + 1:p + 1 + k], "big"), 1 + k
    body = raw[p + h:p + h + n]
    if t == 13:
        body = bytes(range(1, 33))
    out += bytes([0xC0 | t, 255]) + len(body).to_bytes(4, "big") + body
    p += h + n
open(f"{S}/ctrluid.bin", "wb").write(out)
PY
armor "$scratch/ctrluid.asc" "$scratch/ctrluid.bin"
WANT="user ID" refuse "$check" "$scratch/ctrluid.asc"
# Realistic release keys pass: a primary with a signing subkey (embedded
# back-signature), for Ed25519 and for RSA.
for algo in ed25519 rsa3072; do
    h="$scratch/gnupg-$algo"
    mkdir -m 700 "$h"
    gpg --homedir "$h" --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key 'Release Fixture <release@example.invalid>' "$algo" cert never > /dev/null 2>&1
    pf="$(gpg --homedir "$h" --with-colons --list-keys 2> /dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    gpg --homedir "$h" --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$pf" "$algo" sign 2y > /dev/null 2>&1
    gpg --homedir "$h" --armor --export "$pf" > "$scratch/release-$algo.asc" 2> /dev/null
    accept "$scratch/release-$algo.asc"
    gpgconf --homedir "$h" --kill all > /dev/null 2>&1 || true
done
: > "$scratch/empty.asc"
refuse "$check" "$scratch/empty.asc"
# gpg missing: a PATH with only python3 and core tools, no gpg.
mkdir "$scratch/nogpg"
for tool in python3 bash env mktemp chmod rm grep awk cat tr; do
    p="$(command -v "$tool")" && ln -s "$p" "$scratch/nogpg/$tool"
done
refuse env PATH="$scratch/nogpg" "$check" "$scratch/pub.asc"

echo "[ok] verify-public-key controls"
