<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Ported from github.com/3leaps/docpresser RELEASE_CHECKLIST.md at 21e0cad. -->

# Release Checklist

No fuzzmuster release has been cut, and the release signing pin does not
exist yet. Before the first release a maintainer creates it once (see
[Public Pin Maintenance](#public-pin-maintenance)); until then the tag
targets stop with a message saying the pin is missing.

A release is a signed annotated Git tag `vX.Y.Z` on the merged `main`
commit, plus binary archives for every release platform, a `SHA256SUMS`
manifest with a detached GPG signature, and a CycloneDX SBOM, attached to a
GitHub release by the maintainer.

## Pre-Release

### Version Planning

- [ ] All planned changes merged to `main` and tested
- [ ] Breaking changes documented
- [ ] Version number decided (semantic versioning: MAJOR.MINOR.PATCH)

### Code Quality

- [ ] Linux gate passing: `make check`
- [ ] Pre-push gate passing: `make prepush`
- [ ] Release tooling suites passing (throwaway keys only; needs gpg, git,
      python3, jq, GNU Make and Decernor on `PATH` or in
      `FUZZMUSTER_DECERNOR_BIN`; the surface-scan suite also needs
      limensafe and is skipped without it): `make release-tooling-test`
- [ ] Committed public pin agrees with both fingerprint anchors:
      `make release-anchors-check`
- [ ] Public-surface scan with the catalog passing for the release pull
      request: `make pr-final` (needs `LIMENSAFE_CATALOG_PATH` and
      `FUZZMUSTER_SURFACE_PR_TEXT`)
- [ ] Sensitive local data reviewed against the
      [Sensitive Local Data Policy](https://github.com/3leaps/oss-policies/blob/dee9d320f5b7045a44c92b200cc1c92ca83ae843/SENSITIVE-LOCAL-DATA.md);
      none is stored inside the repository tree relying only on `.gitignore`.

### Documentation

- [ ] `README.md` reviewed and updated
- [ ] CLI help text accurate
- [ ] `CHANGELOG.md` has a dated `## [X.Y.Z] - YYYY-MM-DD` section with the
      release entries
- [ ] Release notes written at `docs/releases/vX.Y.Z.md`, and
      `RELEASE_NOTES.md` updated

### Dependencies

- [ ] `go.mod` dependencies reviewed; no local `replace` directives
- [ ] `go mod tidy` leaves no diff
- [ ] Every compiled-in module listed: `make deps-check`
- [ ] Dependency licences pass: `make license-audit`
- [ ] No known vulnerabilities in dependencies

## Release Preparation

### Version Updates

- [ ] Set the version in `VERSION` and the app identity:
      `make version-set V=X.Y.Z`
- [ ] Sync the changelog compare links: `make sync-changelog-links`. For the
      first release, write the footer by hand instead:
      `[Unreleased]: https://github.com/fulmenhq/fuzzmuster/compare/vX.Y.Z...HEAD`
      and `[X.Y.Z]: https://github.com/fulmenhq/fuzzmuster/releases/tag/vX.Y.Z`.
- [ ] Changelog matches `VERSION`: `make release-guard-release-surfaces`
- [ ] Version sanity check:
      `FUZZMUSTER_RELEASE_TAG=vX.Y.Z make release-guard-tag-version`

### Git Hygiene

- [ ] Release preparation merged to `main`; local checkout is on `main` and
      matches `origin/main`
- [ ] `git status` clean
- [ ] Every commit carries the attribution trailers

## Release Execution

### Signing Inputs

The tag is signed with the pinned signing subkey by the committed tagger
identity. Public trust material is committed:
`config/release/tagger-identity.txt`, `config/release/signing-subkey.txt`,
`docs/security/release-signing-keys.asc`, and
`keys/expected-fingerprints.{txt,ndjson}`. See
[docs/security/README.md](docs/security/README.md).

Set in the shell, never in the repository:

| Variable                             | Purpose                                                                                  |
| ------------------------------------ | ---------------------------------------------------------------------------------------- |
| `FUZZMUSTER_RELEASE_TAG`             | Release tag `vX.Y.Z`; must match `VERSION`                                               |
| `FUZZMUSTER_DECERNOR_BIN`            | Absolute path to `decernor` 0.1.8 or newer                                               |
| `FUZZMUSTER_TAG_MESSAGE_DIR`         | Absolute directory outside the repository whose last component is the tag                |
| `FUZZMUSTER_TAGGER_NAME`             | Tagger name; must match `config/release/tagger-identity.txt`                             |
| `FUZZMUSTER_TAGGER_EMAIL`            | Tagger email; must match `config/release/tagger-identity.txt`                            |
| `FUZZMUSTER_GPG_SIGNING_FINGERPRINT` | Approved primary fingerprint (40 uppercase hex)                                          |
| `FUZZMUSTER_PGP_KEY_ID`              | Signing subkey selector `<subkey>!` matching `config/release/signing-subkey.txt`         |
| `FUZZMUSTER_GPG_HOMEDIR`             | Dedicated `0700` GnuPG home outside the repository; never the default GnuPG home         |
| `LIMENSAFE_CATALOG_PATH`             | Public-surface catalog file outside the repository; required by `make release-preflight` |

The catalog must have `catalog_id: fuzzmuster-release` and exactly one
entity whose `replacement_suggestion` is `FuzzmusterCanary`, with one alias:
the scan refuses to trust a catalog that does not block its own canary.

Optional inputs (unset means the default shown):

| Variable                           | Default       | Purpose and constraints                                                                                                                                                                                 |
| ---------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FUZZMUSTER_APPROVED_ENV_LOADER`   | unset         | Maintainer shell file sourced by the tag targets before their guards run. When set it must be an absolute, readable regular file (not a symlink) outside the repository, and it must exit successfully. |
| `FUZZMUSTER_REQUIRE_TAG`           | `0`           | `1` makes the tag version guard also require a clean detached checkout of the pushed tag, matching remote and `origin/main` (needs `GH_TOKEN`).                                                         |
| `FUZZMUSTER_LIMENSAFE_BIN`         | `limensafe`   | Absolute path to the public-surface scanner when it is not on `PATH`.                                                                                                                                   |
| `FUZZMUSTER_SURFACE_SCOPE`         | `pr`          | `release` scans every commit message in history; the pull-request and release targets set it themselves.                                                                                                |
| `FUZZMUSTER_SURFACE_BASE`          | `origin/main` | Base commit for the pull-request commit-message scan.                                                                                                                                                   |
| `FUZZMUSTER_SURFACE_PR_TEXT`       | unset         | Non-empty file holding the pull-request title and body to scan.                                                                                                                                         |
| `FUZZMUSTER_SURFACE_SCAN_REQUIRED` | `0`           | `1` fails instead of skipping when `LIMENSAFE_CATALOG_PATH` is unset; `make pr-final` and the release targets set it themselves.                                                                        |

Must stay unset: `FUZZMUSTER_SURFACE_RELEASE_BASE` (the release scan refuses
any override of its base), `FUZZMUSTER_TEST_FAIL_ANCHOR_INSTALL` (a
fault-injection hook used only by the tooling tests), and
`FUZZMUSTER_SURFACE_BASELINE_ONLY` and `FUZZMUSTER_SURFACE_BRANCH_NAME` (set
only by the CI baseline scan).

The tag comes only from `FUZZMUSTER_RELEASE_TAG`. The version guard and the
tag targets refuse to start while the generic `RELEASE_TAG` is set, even to an
empty value, so `unset RELEASE_TAG` first.

### Tagging (maintainer machine)

- [ ] Remote tag-protection ruleset and immutable-releases setting:
      `make release-github-preflight` (needs a GitHub token with repository
      admin access, which can read the ruleset's bypass list)
- [ ] Pre-tag gate on the merged `main` commit (committed anchor verification,
      `make surface-scan-release`, changelog and compare links, GitHub
      preflight, content-check, dates check, clean-clone test outside the home
      directory, and `make check`): `make release-preflight`
- [ ] Prepare and review the external tag message:
      `make release-prepare-tag-message`. A new message is drafted from the
      dated `CHANGELOG.md` section, copied as written once the changelog
      passes `make release-guard-release-surfaces`. Edit the draft into the
      release summary, delete the review-marker line, and complete the
      attribution footer. Tagging refuses the message until the marker line
      is deleted and the footer is complete; it cannot tell whether the
      summary was edited. An existing message is never overwritten.
- [ ] Create and verify the local signed tag: `make release-tag`
- [ ] Verify the local tag against the committed pin: `make release-verify-tag`
- [ ] Publish and verify the tag (local signature against the committed pin,
      remote object, GitHub `valid`): `make release-push-tag`. The push reports
      the tag ruleset but does not enforce it; `make release-preflight` does,
      so rerun it if anything changed since.
- [ ] Re-verify the published tag from a clean checkout:
      `make release-verify-published-tag` (and
      `make release-verify-remote-tag` to compare local and remote objects)

### Artifacts (maintainer machine)

Build from a clean checkout of the verified tag, so the binaries carry the
tagged version and commit.

- [ ] Build, package and sign: `make package-sign` with the same
      `FUZZMUSTER_RELEASE_TAG`, `FUZZMUSTER_GPG_HOMEDIR`,
      `FUZZMUSTER_PGP_KEY_ID`, `FUZZMUSTER_GPG_SIGNING_FINGERPRINT` and
      `FUZZMUSTER_DECERNOR_BIN` as the tag step. It signs with the committed
      signing subkey only, verifies `SHA256SUMS.asc` in a fresh keyring
      imported only from `docs/security/release-signing-keys.asc`, and
      copies that pin to `dist/release/fuzzmuster-release-signing-key.asc`
      after `scripts/verify-public-key.sh` accepts it. Any failure stops the
      step. Output in `dist/release/`: one archive per release platform,
      `SHA256SUMS`, `SHA256SUMS.asc` and the public key.
- [ ] Re-check the published key file: `make verify-release-key`. It
      accepts only GnuPG's own byte-for-byte export of version 4 public
      keys, with `Name <email>` user IDs of at most 64 bytes and standard
      signature subpackets (see the threat model in `scripts/pubkey-check.py`); a pin exported by
      a different GnuPG version may be refused (fail closed) and must then be
      re-exported and re-reviewed.
- [ ] Generate the SBOM: `make dependencies` (`sbom/fuzzmuster.cdx.json`)
- [ ] Create a draft GitHub release for the tag with the notes from
      `docs/releases/vX.Y.Z.md`, and upload the archives, `SHA256SUMS`,
      `SHA256SUMS.asc`, the public key and the SBOM
- [ ] Publish the release only when every asset is attached: immutable
      releases forbid changing assets after publication

### Public Pin Maintenance

Once before the first release, and again only when the release signing key
changes. Each target refuses to overwrite existing material; replacing a pin
or anchor is a reviewed change that deletes the old file first.

- [ ] Export the approved public key to an absent pin: `make release-export-pin`
- [ ] Validate the existing pin (read-only): `make release-validate-pin`
- [ ] Derive absent fingerprint anchors from the validated pin:
      `make release-insert-anchors`
- [ ] Write `config/release/signing-subkey.txt` (the signing subkey
      fingerprint, the value of `FUZZMUSTER_PGP_KEY_ID` without `!`) and
      `config/release/tagger-identity.txt` (`Name <email>`), one line each
- [ ] Check the committed pin: `make release-anchors-check`, and merge the
      pin through review before tagging

## Post-Release

- [ ] `go install github.com/fulmenhq/fuzzmuster/cmd/fuzzmuster@vX.Y.Z`
      resolves the tagged source
- [ ] A downloaded archive verifies against `SHA256SUMS` and its signature
- [ ] Monitor GitHub issues for release-related bugs

## Notes

- Never skip tests, hooks, or review to speed up a release.
- Signing, tag publication and the release upload are maintainer actions.
  CI holds no release, signing or registry authority.
