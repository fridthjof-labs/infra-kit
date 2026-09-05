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

grep -Fq '"path": "README.md"' "$KIT_ROOT/release-please-config.json" ||
  fail "Release Please does not update the README version pin"
grep -Fq '"path": "docs/consumer.md"' "$KIT_ROOT/release-please-config.json" ||
  fail "Release Please does not update the consumer guide version pins"
pass "release strategy owns consumer-facing version pins"

tag="v${version}"
grep -Fq -- "--version ${tag}" "$KIT_ROOT/README.md" ||
  fail "README version pin and VERSION disagree"
grep -Fq "/${tag}/bootstrap/sync.sh" "$KIT_ROOT/docs/consumer.md" ||
  fail "public bootstrap URL and VERSION disagree"
grep -Fq -- "--version ${tag}" "$KIT_ROOT/docs/consumer.md" ||
  fail "consumer bootstrap command and VERSION disagree"
grep -Fq "ref=${tag}" "$KIT_ROOT/docs/consumer.md" ||
  fail "private bootstrap URL and VERSION disagree"
grep -Fq "INFRA_KIT_VERSION := ${tag}" "$KIT_ROOT/docs/consumer.md" ||
  fail "consumer Makefile and VERSION disagree"
# Check the actual upgrade block, not just the install/Makefile pins above.
upgrade="$(awk '/^## Upgrading/{flag=1;next} /^## /{flag=0} flag' "$KIT_ROOT/docs/consumer.md")"
[[ "$upgrade" == *"<!-- x-release-please-start-version -->"* ]] ||
  fail "Release Please does not own the upgrade example"
[[ "$upgrade" == *"make sync-hack INFRA_KIT_VERSION=${tag}"* ]] ||
  fail "upgrade command and VERSION disagree"
pass "consumer-facing version pins match VERSION"

grep -Fq 'googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7' \
  "$KIT_ROOT/.github/workflows/release.yml" ||
  fail "release workflow is not pinned to the proved Release Please action"
pass "release workflow pins Release Please v5"

# Tidebot merges as github-actions[bot], whose push cannot trigger this
# workflow's `push` event. Without a second trigger the tag is not cut until
# someone else pushes, and consumers pinning the new version get a 404.
grep -Fq 'workflows: [Tidebot]' "$KIT_ROOT/.github/workflows/release.yml" ||
  fail "release workflow does not run after a Tidebot merge"
pass "release runs after Tidebot merges to main"
