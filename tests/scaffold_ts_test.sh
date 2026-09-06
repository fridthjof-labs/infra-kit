#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "scaffold-ts"

repo="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-scaffold-ts.XXXXXX")"
trap 'rm -rf -- "$repo"' EXIT
git -C "$repo" init -q
bash "$KIT_ROOT/bootstrap/sync.sh" --version test \
  --vendor-dir "$repo/hack/vendor/infra-kit" --source "$KIT_ROOT" >/dev/null

sha="0123456789abcdef0123456789abcdef01234567"
out="$(cd "$repo" && bash hack/vendor/infra-kit/bootstrap/scaffold-ts.sh \
  --node 24.18.0 --pm pnpm --pm-version 11.12.0 --kit-ref "$sha" 2>&1)" || fail "scaffold-ts failed: $out"

for path in mise.toml .github/workflows/ci.yml .github/tidebot.yaml .gitignore; do
  [[ -f "$repo/$path" ]] || fail "scaffold-ts did not write $path"
done
pass "the TypeScript baseline is written"

grep -q '^node = "24.18.0"' "$repo/mise.toml" || fail "node not pinned"
grep -q '^pnpm = "11.12.0"' "$repo/mise.toml" || fail "pnpm not pinned"
grep -q 'run = "pnpm check"' "$repo/mise.toml" || fail "check task does not run the package script"
pass "toolchain pinned once, check task defined"

grep -q "ts-ci.yml@$sha " "$repo/.github/workflows/ci.yml" || fail "ci.yml is not pinned to --kit-ref"
grep -q -- '- ci / check' "$repo/.github/tidebot.yaml" || fail "tidebot gate does not match the called job name"
pass "CI calls the reusable workflow by SHA; the gate names its job"

if (cd "$repo" && bash hack/vendor/infra-kit/bootstrap/scaffold-ts.sh \
  --node 24.18.0 --pm yarn --pm-version 1.0.0 --kit-ref "$sha" >/dev/null 2>&1); then
  fail "scaffold-ts accepted yarn"
fi
pass "pnpm or bun only"
