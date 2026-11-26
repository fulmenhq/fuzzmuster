#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Ported from github.com/3leaps/docpresser scripts/release-tooling-test.sh at 21e0cad.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
suites="$root/config/release/tooling-suites.txt"
[[ -f "$suites" && ! -L "$suites" ]] || {
    echo 'error: missing config/release/tooling-suites.txt' >&2
    exit 1
}
# Every scripts/*.test.sh is either a release tooling suite listed in the
# suites file or one of these suites that `make check` runs instead (content
# check controls and deps-check controls), so no suite can go unrun.
check_suites=(content-check deps-check)
listed="$(grep -v '^#' "$suites")"
expected="$(printf '%s\n' "$listed" "${check_suites[@]}" | LC_ALL=C sort)"
actual="$(find "$root/scripts" -maxdepth 1 -name '*.test.sh' -print | sed 's|.*/||; s|\.test\.sh$||' | LC_ALL=C sort)"
[[ "$expected" == "$actual" ]] || {
    echo 'error: scripts/*.test.sh does not match config/release/tooling-suites.txt and the make check suites' >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    exit 1
}
# Suites use throwaway keys and fixtures only. Clear the maintainer's release
# environment so a real tag, keyring, key id or catalog can never leak into a
# fixture; only the designated checker path is passed through. Every GIT_*
# variable is cleared too (repository redirects such as GIT_DIR, and injected
# configuration such as GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS).
#
# Git configuration is sealed in a way the production scripts' own GIT_* scrubs
# cannot undo when a suite sources them: HOME and XDG_CONFIG_HOME point at a
# private directory whose only git configuration is a fixture identity with
# signing off, and GIT_CONFIG_NOSYSTEM=1 (which those scrubs keep) hides system
# configuration. A self-check below proves the seal survives a sourced scrub.
scrub=()
while IFS= read -r name; do
    [[ "$name" == FUZZMUSTER_DECERNOR_BIN ]] || scrub+=(-u "$name")
done < <(compgen -e | grep -E '^(FUZZMUSTER_|LIMENSAFE_|GNUPGHOME$|GIT_|XDG_CONFIG_HOME$)' || true)
sealed_home="$(mktemp -d "${TMPDIR:-/tmp}/release-tooling-home.XXXXXX")"
trap 'rm -rf "$sealed_home"' EXIT
mkdir -m 700 "$sealed_home/.config"
cat > "$sealed_home/.gitconfig" << 'GITCONFIG'
[user]
	name = Release Tooling Fixture
	email = fixture@example.invalid
[commit]
	gpgsign = false
[tag]
	gpgsign = false
[init]
	defaultBranch = main
GITCONFIG
sealed() {
    env ${scrub[@]+"${scrub[@]}"} HOME="$sealed_home" XDG_CONFIG_HOME="$sealed_home/.config" \
        GIT_CONFIG_NOSYSTEM=1 "$@"
}
# The self-check reads configuration from inside the sealed home with
# repository discovery stopped at that directory (GIT_CEILING_DIRECTORIES is set
# on each git call, after the sourced scrub), so a repository-local identity or
# signing setting in an enclosing checkout, even when TMPDIR lies inside one,
# cannot trip it. Such settings never reach freshly initialized fixtures.
sealed bash -c '
    cd "$2" || exit 1
    source "$1/scripts/release-tag-common.sh" > /dev/null 2>&1 || true
    cfg() { GIT_CEILING_DIRECTORIES="$(dirname "$2")" git config --get "$1"; }
    ! GIT_CEILING_DIRECTORIES="$(dirname "$2")" git rev-parse --git-dir > /dev/null 2>&1 &&
        [[ "${GIT_CONFIG_NOSYSTEM:-}" == 1 ]] &&
        [[ "$(cfg user.email "$2")" == fixture@example.invalid ]] &&
        [[ "$(cfg commit.gpgsign "$2")" == false ]] &&
        [[ "$(cfg tag.gpgsign "$2")" == false ]] &&
        [[ -z "$(cfg gpg.program "$2")" ]]
' _ "$root" "$sealed_home" || {
    echo 'error: sealed git configuration did not survive a sourced production scrub' >&2
    exit 1
}
while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    sealed "$root/scripts/$suite.test.sh"
done <<< "$listed"
echo "[ok] all $(grep -c . <<< "$listed") release tooling suites passed"
