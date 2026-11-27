#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check that copied third-party schemas match the checksums in PROVENANCE.md.

Every file under schemas/third_party/<source>/schemas/ must be listed in that
source's PROVENANCE.md with its SHA-256, and every listed file must exist and
match. A copied schema is never edited in place.
"""

import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "schemas", "third_party")
LINE = re.compile(r"^([0-9a-f]{64})  (schemas/\S+)$")


def main():
    problems = []
    sources = sorted(
        d for d in os.listdir(BASE) if os.path.isdir(os.path.join(BASE, d))
    )
    if not sources:
        problems.append("no third-party sources")
    for source in sources:
        src = os.path.join(BASE, source)
        with open(os.path.join(src, "PROVENANCE.md"), encoding="utf-8") as handle:
            listed = dict(
                (m.group(2), m.group(1))
                for m in (LINE.match(line.rstrip("\n")) for line in handle)
                if m
            )
        present = set()
        for base, _, files in os.walk(os.path.join(src, "schemas")):
            for name in files:
                present.add(
                    os.path.relpath(os.path.join(base, name), src).replace(os.sep, "/")
                )
        for rel in sorted(present - set(listed)):
            problems.append("%s: %s is not listed in PROVENANCE.md" % (source, rel))
        for rel, digest in sorted(listed.items()):
            path = os.path.join(src, *rel.split("/"))
            if not os.path.isfile(path):
                problems.append("%s: %s is listed but missing" % (source, rel))
                continue
            with open(path, "rb") as handle:
                if hashlib.sha256(handle.read()).hexdigest() != digest:
                    problems.append(
                        "%s: %s does not match its checksum" % (source, rel)
                    )
    for problem in problems:
        print("third-party-check: " + problem, file=sys.stderr)
    if problems:
        return 1
    print("[ok] third-party-check: copied schemas match PROVENANCE.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
