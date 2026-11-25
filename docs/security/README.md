<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Ported from github.com/3leaps/docpresser docs/security/README.md at 21e0cad. -->

# Release verification

fuzzmuster has no release yet, and no release signing pin is committed.
This page describes the trust model the release tooling enforces once the
pin exists; until then every signing and tag-verification step stops with
a message saying the pin is missing.

Each release is a GPG-signed annotated Git tag `vX.Y.Z`, plus binary
archives whose `SHA256SUMS` manifest carries a detached GPG signature
(`SHA256SUMS.asc`) from the same key.

Establish the expected GPG primary and exact signing subkey through an
independently trusted maintainer channel before accepting a downloaded public
key. A key distributed beside a signature is not independent authentication.

## Committed trust material

Created once by a maintainer (see Public Pin Maintenance in
[RELEASE_CHECKLIST.md](../../RELEASE_CHECKLIST.md)); none of these files
exists yet:

| File                                     | Holds                                                 |
| ---------------------------------------- | ----------------------------------------------------- |
| `docs/security/release-signing-keys.asc` | Public pin: one primary and one signing subkey        |
| `keys/expected-fingerprints.txt`         | Primary fingerprint anchor, `gpg <fingerprint>`       |
| `keys/expected-fingerprints.ndjson`      | The same anchor as a Decernor fingerprint record      |
| `config/release/signing-subkey.txt`      | Fingerprint of the one permitted signing subkey       |
| `config/release/tagger-identity.txt`     | Tagger identity `Name <email>` every release tag uses |

Tag verification extracts these from the verified tagged commit as inert
blobs, not from the current checkout.

## Checks

The text and NDJSON anchors record the pinned primary under Decernor's
`openpgp-fingerprint-v1` scheme. Check the pin against both anchors with
Decernor 0.1.8 or newer:

```sh
make release-anchors-check
```

The check re-derives the primary fingerprint record from the pin with
`decernor fingerprint --class public --kind gpg --gpg-role primary` and
requires both anchor files to match it exactly.

Tag verification (`scripts/verify-pinned-tag.sh`, `make release-verify-tag`)
uses an isolated keyring and requires the exact signing subkey and the
committed tagger identity. GitHub Verified with reason `valid` is an
additional check (`make release-verify-published-tag`).

To check downloaded archives, import the pin into an empty, isolated GnuPG
home, verify `SHA256SUMS.asc` against `SHA256SUMS`, confirm the signature
was made by the pinned signing subkey, then check each archive against
`SHA256SUMS`.
