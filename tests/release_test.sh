#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "release configuration"
version="$(tr -d '\n' < "$KIT_ROOT/VERSION")"

grep -Fq "\".\": \"${version}\"" "$KIT_ROOT/.release-please-manifest.json" ||
  fail "release manifest and VERSION disagree"
pass "manifest starts from VERSION"

grep -Fq '"release-type": "simple"' "$KIT_ROOT/release-please-config.json" ||
  fail "release type is not simple"
grep -Fq '"version-file": "VERSION"' "$KIT_ROOT/release-please-config.json" ||
  fail "Release Please does not own VERSION"
pass "simple release strategy owns VERSION"

grep -Fq 'googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7' \
  "$KIT_ROOT/.github/workflows/release.yml" ||
  fail "release workflow is not pinned to the proved Release Please action"
pass "release workflow pins Release Please v5"
