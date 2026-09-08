#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "scaffold-go"

repo="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-scaffold-go.XXXXXX")"
trap 'rm -rf -- "$repo"' EXIT
git -C "$repo" init -q
bash "$KIT_ROOT/bootstrap/sync.sh" --version test \
  --vendor-dir "$repo/hack/vendor/infra-kit" --source "$KIT_ROOT" >/dev/null

sha="0123456789abcdef0123456789abcdef01234567"
out="$(cd "$repo" && bash hack/vendor/infra-kit/bootstrap/scaffold-go.sh \
  --module github.com/testorg/thing --go 1.24.0 --kit-ref "$sha" \
  --private-modules kit,intelligence 2>&1)" || fail "scaffold-go failed: $out"

for path in mise.toml Makefile .golangci.yml tools/go.mod \
  .github/workflows/ci.yml .github/tidebot.yaml .gitignore; do
  [[ -f "$repo/$path" ]] || fail "scaffold-go did not write $path"
done
pass "the Go baseline is written"

grep -q '^go = "1.24.0"' "$repo/mise.toml" || fail "mise.toml does not pin the floor"
grep -q '^go 1.24.0$' "$repo/tools/go.mod" || fail "tools/go.mod does not pin the floor"
grep -q '^module github.com/testorg/thing/tools$' "$repo/tools/go.mod" || fail "tools module path wrong"
pass "one floor, stated in mise.toml and tools/go.mod"

grep -q "go-ci.yml@$sha " "$repo/.github/workflows/ci.yml" || fail "ci.yml is not pinned to --kit-ref"
grep -q "private-modules: 'kit,intelligence'" "$repo/.github/workflows/ci.yml" || fail "private modules not passed"
if grep -E 'uses: [^ ]+@' "$repo/.github/workflows/ci.yml" | grep -vqE '@[0-9a-f]{40} '; then
  fail "generated workflow has an unpinned reference"
fi
grep -q 'name: required checks' "$repo/.github/workflows/ci.yml" || fail "aggregator missing"
grep -q -- '- required checks' "$repo/.github/tidebot.yaml" || fail "tidebot gate missing"
pass "CI calls the reusable workflow by SHA and keeps the required-checks name"

if (cd "$repo" && bash hack/vendor/infra-kit/bootstrap/scaffold-go.sh \
  --module github.com/testorg/thing --go 1.24.0 --kit-ref "$sha" >/dev/null 2>&1); then
  fail "scaffold-go overwrote existing files"
fi
pass "refuses to overwrite"

if (cd "$repo" && rm -f mise.toml && bash hack/vendor/infra-kit/bootstrap/scaffold-go.sh \
  --module github.com/testorg/thing --go 1.24.0 --kit-ref v0.4.0 >/dev/null 2>&1); then
  fail "scaffold-go accepted a tag as --kit-ref"
fi
pass "a tag is not a pin"

grep -q "workflow-ci.yml@$sha " "$repo/.github/workflows/ci.yml" || fail "workflow validation gate missing"
grep -q "needs: workflows" "$repo/.github/workflows/ci.yml" || fail "baseline does not depend on workflow validation"
pass "workflow validation blocks the baseline before expensive checks"
