#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# From the Fulmen Go microtool template (scripts/package-artifacts.sh).
set -euo pipefail

# Package release artifacts for fuzzmuster.
# Builds archives for each OS/arch with checksums; optional GPG signing via SIGN=1.
#
# Usage:
#   SIGN=1 ./scripts/package-artifacts.sh   # signs with the committed pin (fails closed)
#
# Notes:
# - Expects binaries already built in ./bin (use `make build-all` first).
# - BINARY_NAME can be overridden via env; defaults to "fuzzmuster".
# - Archives land in dist/release alongside SHA256SUMS (and optional .asc).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PROJECT="${BINARY_NAME:-fuzzmuster}"
VERSION="$(tr -d ' \t\r\n' < VERSION)"
BIN_DIR="bin"
OUT_DIR="dist/release"
OUT_DIR_ABS="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/SHA256SUMS" "${OUT_DIR}/SHA256SUMS.asc"

package() {
    local os="$1" arch="$2"
    local ext="" archive_ext="tar.gz"
    local bin="${BIN_DIR}/${PROJECT}-${os}-${arch}"
    local archive_name="${PROJECT}_${VERSION}_${os}_${arch}.${archive_ext}"

    if [[ "${os}" == "windows" ]]; then
        ext=".exe"
        bin="${bin}${ext}"
        archive_ext="zip"
        archive_name="${PROJECT}_${VERSION}_${os}_${arch}.${archive_ext}"
    fi

    if [[ ! -f "${bin}" ]]; then
        echo "Skipping ${os}/${arch}: binary not found: ${bin}" >&2
        return
    fi

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    local bin_name="${PROJECT}${ext}"
    cp "${bin}" "${tmpdir}/${bin_name}"
    chmod +x "${tmpdir}/${bin_name}"

    case "${archive_ext}" in
        tar.gz)
            (cd "${tmpdir}" && tar -czf "${OUT_DIR_ABS}/${archive_name}" "${bin_name}")
            ;;
        zip)
            # Prefer the `zip` CLI; fall back to python3 (the goneat-tools
            # runner image ships python3 but not zip).
            if command -v zip > /dev/null 2>&1; then
                (cd "${tmpdir}" && zip -q "${OUT_DIR_ABS}/${archive_name}" "${bin_name}")
            elif command -v python3 > /dev/null 2>&1; then
                (cd "${tmpdir}" && python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); z.write(sys.argv[2]); z.close()' "${OUT_DIR_ABS}/${archive_name}" "${bin_name}")
            else
                echo "Neither zip nor python3 available to create ${archive_name}" >&2
                exit 1
            fi
            ;;
    esac

    if command -v shasum > /dev/null 2>&1; then
        (cd "${OUT_DIR_ABS}" && shasum -a 256 "${archive_name}") >> "${OUT_DIR_ABS}/SHA256SUMS"
    elif command -v sha256sum > /dev/null 2>&1; then
        (cd "${OUT_DIR_ABS}" && sha256sum "${archive_name}") >> "${OUT_DIR_ABS}/SHA256SUMS"
    else
        echo "No sha256 tool available" >&2
        exit 1
    fi

    echo "Packaged ${archive_name}"
}

# Build matrix (aligns with make build-all)
package linux amd64
package linux arm64
package darwin arm64
package windows amd64
package windows arm64

# Signing (SIGN=1, maintainer only). Bound to the same committed pin and
# signing-subkey selector as the release tag; fails closed at every step.
case "${SIGN:-0}" in
    0) ;;
    1)
        command -v gpg > /dev/null 2>&1 || {
            echo "error: SIGN=1 requires gpg" >&2
            exit 1
        }
        # shellcheck source=scripts/release-tag-common.sh
        source "${ROOT_DIR}/scripts/release-tag-common.sh"
        trap 'tag_cleanup_homes' EXIT
        tag_version || exit 1
        tag_key_selector || exit 1
        tag_prepare_signing_home || exit 1
        gpg --batch --yes --armor --local-user "${FUZZMUSTER_PGP_KEY_ID}" \
            --detach-sign -o "${OUT_DIR_ABS}/SHA256SUMS.asc" "${OUT_DIR_ABS}/SHA256SUMS" || {
            echo "error: signing SHA256SUMS failed" >&2
            exit 1
        }
        # Verify against the committed pin only, in a fresh keyring.
        tag_fresh_verify_gnupg_home || exit 1
        gpg --homedir "$TAG_VERIFY_GNUPGHOME" --batch --quiet --import \
            "${ROOT_DIR}/docs/security/release-signing-keys.asc" 2> /dev/null || {
            echo "error: committed public pin failed to import" >&2
            exit 1
        }
        status="$(gpg --homedir "$TAG_VERIFY_GNUPGHOME" --batch --status-fd 1 \
            --verify "${OUT_DIR_ABS}/SHA256SUMS.asc" "${OUT_DIR_ABS}/SHA256SUMS" 2> /dev/null)" || {
            echo "error: SHA256SUMS.asc does not verify against the committed pin" >&2
            exit 1
        }
        primary="$(awk '$2=="VALIDSIG" {print $12}' <<< "$status")"
        [[ "$primary" == "$FUZZMUSTER_GPG_SIGNING_FINGERPRINT" ]] || {
            echo "error: SHA256SUMS.asc is not signed by the pinned primary key" >&2
            exit 1
        }
        tag_discard_verify_home
        # Publish the committed pin itself, after checking it is public-only.
        cp "${ROOT_DIR}/docs/security/release-signing-keys.asc" "${OUT_DIR_ABS}/${PROJECT}-release-signing-key.asc"
        "${ROOT_DIR}/scripts/verify-public-key.sh" "${OUT_DIR_ABS}/${PROJECT}-release-signing-key.asc"
        echo "Signed and verified SHA256SUMS -> SHA256SUMS.asc"
        ;;
    *)
        echo "error: SIGN must be 0 or 1" >&2
        exit 1
        ;;
esac

echo "Artifacts in ${OUT_DIR_ABS}:"
ls -lh "${OUT_DIR_ABS}"
