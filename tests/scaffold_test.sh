#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "scaffold"

repo="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-scaffold.XXXXXX")"
trap 'rm -rf -- "$repo"' EXIT

git -C "$repo" init -q

bash "$KIT_ROOT/bootstrap/sync.sh" \
  --version test \
  --vendor-dir "$repo/hack/vendor/infra-kit" \
  --source "$KIT_ROOT" >/dev/null

out="$(cd "$repo" && bash hack/vendor/infra-kit/bootstrap/scaffold.sh \
  --state-prefix testorg --root site 2>&1)" || fail "scaffold failed: $out"

for path in \
  Makefile mise.toml .gitignore \
  tofu/.sops.yaml tofu/ops.env.example \
  tofu/site/versions.tf tofu/site/main.tf \
  .github/workflows/infra.yml; do
  [[ -f "$repo/$path" ]] || fail "scaffold did not write $path"
done
pass "the canonical layout is written"

grep -q 'INFRA_KIT_STATE_PREFIX := testorg' "$repo/Makefile" || fail "Makefile missing state prefix"
grep -q 'INFRA_KIT         := hack/vendor/infra-kit' "$repo/Makefile" ||
  fail "Makefile does not point at the real vendor location"
grep -q 'ROOT ?= site' "$repo/Makefile" || fail "Makefile missing default root"
pass "the Makefile is parameterized, not generic"

# Every action in the generated workflow is pinned to a commit SHA; a tag can
# be moved to point at different code.
if grep -E 'uses: [^ ]+' "$repo/.github/workflows/infra.yml" | grep -vqE '@[0-9a-f]{40} '; then
  fail "generated workflow has an unpinned action"
fi
grep -q 'SOPS_AGE_KEY' "$repo/.github/workflows/infra.yml" || fail "workflow missing the one CI secret"
pass "the generated workflow is SHA-pinned with a single secret"

# The scaffold refuses to overwrite an existing layout.
if out="$(cd "$repo" && bash hack/vendor/infra-kit/bootstrap/scaffold.sh \
  --state-prefix testorg --root site 2>&1)"; then
  fail "scaffold overwrote an existing layout"
fi
[[ "$out" == *"refusing to overwrite"* ]] || fail "wrong refusal: $out"
pass "an existing layout is never overwritten"

# The scaffolded validate refuses to run until the placeholders are replaced…
mkdir -p "$repo/stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/stub/tofu"
chmod +x "$repo/stub/tofu"
export PATH="$repo/stub:$PATH"

if (cd "$repo" && make validate) >/dev/null 2>&1; then
  fail "validate passed with REPLACE_WITH placeholders in .sops.yaml"
fi
pass "validate blocks until the recipients are real"

# …and passes end to end once they are.
age-keygen -o "$repo/identity.txt" 2>/dev/null
echo 'identity.txt' >> "$repo/.gitignore"
recipient="$(grep -o 'age1[0-9a-z]*' "$repo/identity.txt" | head -1)"
sed -i.bak \
  -e "s/REPLACE_WITH_OPERATOR_RECIPIENT,/${recipient}/" \
  -e '/REPLACE_WITH_CI_RECIPIENT,/d' \
  -e '/REPLACE_WITH_RECOVERY_RECIPIENT/d' \
  "$repo/tofu/.sops.yaml" && rm -f "$repo/tofu/.sops.yaml.bak"

out="$(cd "$repo" && make validate 2>&1)" || fail "scaffolded make validate failed: $out"
pass "the scaffolded repository validates out of the box"

# The documented first encryption works against the scaffolded rules.
cp "$repo/tofu/ops.env.example" "$repo/tofu/ops.env"
out="$(cd "$repo" && SOPS_AGE_KEY_FILE="$repo/identity.txt" make encrypt-ops 2>&1)" ||
  fail "make encrypt-ops failed on the scaffolded layout: $out"
[[ -f "$repo/tofu/ops.env.enc" ]] || fail "ops.env.enc was not written"
[[ ! -f "$repo/tofu/ops.env" ]] || fail "plaintext ops.env survived encryption"
pass "the operations file encrypts through the scaffolded Makefile"
