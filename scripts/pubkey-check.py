#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Structural check of an OpenPGP public key file, from the raw bytes.

Usage: pubkey-check.py KEY_FILE

Called by verify-public-key.sh before any GnuPG step. Refuses the file
unless every byte is accounted for:

- printable ASCII; exactly one public key block; no armor headers; a
  canonical base64 body; a CRC24 line that matches (when present); nothing
  outside the block but whitespace;
- the body decodes to packets that parse end to end: public key (6), user ID
  (13), public subkey (14), signature (2) and marker (10), starting with a
  public key;
- each key packet is version 4 with a known algorithm and exactly its key
  material; each signature is version 4 with exactly its subpackets and
  signature values; subpackets are an allowlist with length caps; notations
  are only GnuPG's own short ones (manu, salt); an embedded signature is
  checked by the same rules; user IDs are short ASCII of the form
  Name <email> (at most 64 bytes, no base64 symbols).

Threat model: this guards against secret key material reaching a published
file by mistake: a secret-key packet, a second block, trailing bytes, armor
headers or non-canonical armor are refused. A user ID (at most 64 bytes), a
notation value (at most 32 bytes), Ed25519 or X25519 public material (32
bytes) and an Ed25519 signature value (64 bytes) are each too small for the
smallest unencrypted secret-key packet (75 bytes). MPIs (RSA, DSA, ECDSA,
legacy EdDSA) and an embedded signature subpacket are not capped below the
file limit and can carry one; this script accepts such a file, and the
byte-for-byte GnuPG re-export in verify-public-key.sh is what refuses it
when GnuPG does not keep that material. That is GnuPG's handling, not a
size limit. Deliberate steganography by the key holder is out of scope: a
seed in the 32-byte salt notation, in a signature value, or in other opaque
bytes the holder signs cannot be excluded by any checker, and whoever can
craft the pin already holds the key. The pin is a reviewed,
fingerprint-anchored trust file.
"""

import base64
import binascii
import re
import sys

MAX_FILE = 64 * 1024
MAX_UID = 64
# Name <email> or Name (comment) <email>: letters, digits, spaces and common
# name punctuation; no base64 symbols. At most 64 bytes: smaller than the
# smallest unencrypted secret-key packet (75 bytes).
UID = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9 .,'-]{0,39}( \([A-Za-z0-9][A-Za-z0-9 .,'-]{0,23}\))? "
    r"<[a-z0-9][a-z0-9._-]{0,31}@[a-z0-9-]+(\.[a-z0-9-]+)+>"
)
NOTATION_NAMES = {b"manu", b"salt@notations.gnupg.org"}
NOTATION_MAX_VALUE = 32
# subpacket type -> maximum data length (excluding the type octet)
SUBPACKETS = {
    2: 4,  # signature creation time
    3: 4,  # signature expiration time
    9: 4,  # key expiration time
    11: 16,  # preferred symmetric algorithms
    16: 8,  # issuer key ID
    20: 8 + max(len(n) for n in NOTATION_NAMES) + NOTATION_MAX_VALUE,  # notation
    21: 16,  # preferred hash algorithms
    22: 8,  # preferred compression algorithms
    23: 4,  # key server preferences
    25: 1,  # primary user ID
    27: 4,  # key flags
    30: 4,  # features
    32: 1024,  # embedded signature (checked recursively)
    33: 33,  # issuer fingerprint
    34: 16,  # preferred AEAD algorithms
    35: 33,  # intended recipient fingerprint
    39: 32,  # preferred AEAD ciphersuites
}


class Refused(Exception):
    pass


def need(cond, why):
    if not cond:
        raise Refused(why)


class Reader:
    def __init__(self, data, what):
        self.data, self.pos, self.what = data, 0, what

    def take(self, n):
        need(n >= 0 and self.pos + n <= len(self.data), f"truncated {self.what}")
        out = self.data[self.pos : self.pos + n]
        self.pos += n
        return out

    def u(self, n):
        return int.from_bytes(self.take(n), "big")

    def done(self):
        return self.pos == len(self.data)

    def finish(self):
        need(self.done(), f"extra data inside {self.what}")


def mpi(r):
    bits = r.u(2)
    need(bits > 0, f"empty MPI in {r.what}")
    r.take((bits + 7) // 8)


def ec_point(r):
    oid_len = r.u(1)
    need(1 <= oid_len <= 16, f"bad curve OID in {r.what}")
    r.take(oid_len)
    mpi(r)


def check_key(body, what):
    r = Reader(body, what)
    need(r.u(1) == 4, f"{what} is not version 4")
    r.take(4)  # creation time
    algo = r.u(1)
    if algo in (1, 2, 3):  # RSA: n, e
        mpi(r)
        mpi(r)
    elif algo == 17:  # DSA: p, q, g, y
        for _ in range(4):
            mpi(r)
    elif algo in (19, 22):  # ECDSA, EdDSA (legacy): OID, point
        ec_point(r)
    elif algo == 18:  # ECDH: OID, point, KDF parameters
        ec_point(r)
        kdf_len = r.u(1)
        need(kdf_len == 3, f"bad ECDH KDF parameters in {what}")
        need(r.u(1) == 1, f"bad ECDH KDF parameters in {what}")
        r.take(2)
    elif algo == 25:  # X25519
        r.take(32)
    elif algo == 27:  # Ed25519
        r.take(32)
    else:
        raise Refused(f"{what} uses unsupported public-key algorithm {algo}")
    r.finish()
    return algo


def check_subpackets(area, what):
    r = Reader(area, what)
    while not r.done():
        first = r.u(1)
        if first < 192:
            length = first
        elif first < 255:
            length = ((first - 192) << 8) + r.u(1) + 192
        else:
            length = r.u(4)
        need(length >= 1, f"empty subpacket in {what}")
        stype = r.u(1) & 0x7F
        data = r.take(length - 1)
        need(stype in SUBPACKETS, f"signature subpacket type {stype} is not allowed")
        need(
            len(data) <= SUBPACKETS[stype],
            f"oversized signature subpacket type {stype} ({len(data)} bytes)",
        )
        if stype == 20:
            n = Reader(data, "notation")
            n.take(4)  # flags
            name_len, value_len = n.u(2), n.u(2)
            name = n.take(name_len)
            n.take(value_len)
            n.finish()
            need(name in NOTATION_NAMES, "a signature notation that is not allowed")
            need(value_len <= NOTATION_MAX_VALUE, "an oversized signature notation")
        elif stype == 32:
            check_signature(data, "embedded signature")


def check_signature(body, what="signature"):
    r = Reader(body, what)
    need(r.u(1) == 4, f"{what} is not version 4")
    r.take(1)  # signature type
    algo = r.u(1)
    r.take(1)  # hash algorithm
    check_subpackets(r.take(r.u(2)), f"{what} hashed area")
    check_subpackets(r.take(r.u(2)), f"{what} unhashed area")
    r.take(2)  # left 16 bits of the hash
    if algo in (1, 2, 3):
        mpi(r)
    elif algo in (17, 19, 22):
        mpi(r)
        mpi(r)
    elif algo == 27:
        r.take(64)
    else:
        raise Refused(f"{what} uses unsupported algorithm {algo}")
    r.finish()


def check_uid(body):
    need(1 <= len(body) <= MAX_UID, "a user ID that is empty or longer than 64 bytes")
    try:
        text = body.decode("ascii")
    except UnicodeDecodeError:
        raise Refused("a user ID that is not plain ASCII")
    need(UID.fullmatch(text), "a user ID that is not of the form Name <email>")


def packets(raw):
    r = Reader(raw, "packet stream")
    while not r.done():
        ctb = r.u(1)
        need(ctb & 0x80, "invalid packet header")
        if ctb & 0x40:
            tag, first = ctb & 0x3F, r.u(1)
            if first < 192:
                length = first
            elif first < 224:
                length = ((first - 192) << 8) + r.u(1) + 192
            elif first == 255:
                length = r.u(4)
            else:
                raise Refused("partial body lengths are not allowed in a key")
        else:
            tag, ltype = (ctb >> 2) & 0x0F, ctb & 0x03
            need(ltype != 3, "indeterminate packet length")
            length = r.u((1, 2, 4)[ltype])
        yield tag, r.take(length)


def dearmor(data):
    need(len(data) <= MAX_FILE, "file is larger than 64 KiB")
    need(
        all(0x20 <= b <= 0x7E or b in (0x09, 0x0A, 0x0D) for b in data),
        "non-ASCII or control bytes present",
    )
    lines = data.decode("ascii").replace("\r\n", "\n").split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    need(
        len(lines) >= 3
        and lines[0] == "-----BEGIN PGP PUBLIC KEY BLOCK-----"
        and lines[-1] == "-----END PGP PUBLIC KEY BLOCK-----",
        "not a single public key block",
    )
    need(lines[1] == "", "armor headers are not allowed")
    payload = lines[2:-1]
    crc = payload.pop() if payload and payload[-1].startswith("=") else None
    need(payload, "empty armor body")
    for line in payload:
        need(
            re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", line), "non-base64 line in armor body"
        )
    joined = "".join(payload)
    try:
        raw = base64.b64decode(joined, validate=True)
    except binascii.Error:
        raise Refused("invalid base64")
    need(base64.b64encode(raw).decode() == joined, "non-canonical base64")
    if crc is not None:
        c = 0xB704CE
        for b in raw:
            c ^= b << 16
            for _ in range(8):
                c <<= 1
                if c & 0x1000000:
                    c ^= 0x1864CFB
        need(
            re.fullmatch(r"=[A-Za-z0-9+/]{4}", crc)
            and base64.b64decode(crc[1:]) == (c & 0xFFFFFF).to_bytes(3, "big"),
            "armor checksum mismatch",
        )
    return raw


def main():
    if len(sys.argv) != 2:
        print("usage: pubkey-check.py KEY_FILE", file=sys.stderr)
        return 2
    try:
        raw = dearmor(open(sys.argv[1], "rb").read())
        tags = []
        for tag, body in packets(raw):
            if tag == 6:
                check_key(body, "public key packet")
            elif tag == 14:
                check_key(body, "public subkey packet")
            elif tag == 13:
                check_uid(body)
            elif tag == 2:
                check_signature(body)
            elif tag == 10:
                need(body == b"PGP", "bad marker packet")
            else:
                raise Refused(f"packet type {tag} is not allowed in a public key file")
            tags.append(tag)
        need(tags and tags[0] == 6, "the file does not start with a public key packet")
    except Refused as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
