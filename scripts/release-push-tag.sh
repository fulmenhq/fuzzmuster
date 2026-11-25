#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Ported from github.com/3leaps/docpresser scripts/release-push-tag.sh at 21e0cad.
set -euo pipefail
# shellcheck source=scripts/release-tag-common.sh
source "$(dirname "$0")/release-tag-common.sh"
cd "$tag_root"
"$tag_root/scripts/release-verify-tag.sh"
"$tag_root/scripts/release-inspect-tag-ruleset.sh" "$FUZZMUSTER_RELEASE_TAG"
remote_tag_absent || tag_die 'remote tag already exists'
git push origin "refs/tags/$FUZZMUSTER_RELEASE_TAG"
"$tag_root/scripts/release-verify-remote-tag.sh"
