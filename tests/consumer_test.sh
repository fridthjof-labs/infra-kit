#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "consumer adoption"

# A consumer built by following docs/consumer.md, not by reaching into this
# checkout. The previous tests all used --source and called bootstrap scripts
# from upstream, which is why they never noticed that the documented Makefile
# referenced paths sync.sh had not vendored.
consumer="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-consumer.XXXXXX")"
mkdir -p "$consumer/infra/hack"

git -C "$consumer" init -q
echo 'identity.txt' > "$consumer/.gitignore"

age-keygen -o "$consumer/identity.txt" 2>/dev/null
recipient="$(grep -o 'age1[0-9a-z]*' "$consumer/identity.txt" | head -1)"
cat > "$consumer/infra/.sops.yaml" <<EOF
creation_rules:
  - path_regex: \.(tfvars|hcl)\$
    age: ${recipient}
EOF

# Step 1 of the docs, with --source standing in for the authenticated download.
bash "$KIT_ROOT/bootstrap/sync.sh" \
  --version test \
  --vendor-dir "$consumer/infra/vendor/infra-kit" \
  --source "$KIT_ROOT" >/dev/null
pass "step 1 vendors the payload"

# Step 2: the Makefile is extracted from the documentation itself, so the two
# cannot drift.
awk '/<!-- consumer-makefile:begin -->/{flag=1;next} /<!-- consumer-makefile:end -->/{flag=0} flag' \
  "$KIT_ROOT/docs/consumer.md" | sed '/^```/d' > "$consumer/Makefile"
[[ -s "$consumer/Makefile" ]] || fail "could not extract the Makefile from docs/consumer.md"
grep -q 'include .*make/secrets.mk' "$consumer/Makefile" || fail "extracted Makefile has no shared Make include"
pass "step 2 Makefile extracted from the documentation"

out="$(cd "$consumer" && make verify-infra-kit 2>&1)" ||
  fail "documented 'make verify-infra-kit' failed: $out"
[[ "$out" == *"verified"* ]] || fail "verify did not verify the vendored payload: $out"
pass "documented 'make verify-infra-kit' verifies the payload"

# The target that would have failed before: it invokes the vendored sync.sh,
# which has to replace the very directory it is running from.
out="$(cd "$consumer" && make sync-infra-kit INFRA_KIT_VERSION=test \
  INFRA_KIT_SYNC_SOURCE="$KIT_ROOT" 2>&1)" || true
if [[ "$out" != *"vendored infra-kit"* ]]; then
  # The documented target has no --source, so a network attempt is expected in
  # a sandbox. Drive the vendored script directly to prove self-replacement.
  out="$(cd "$consumer" && bash infra/vendor/infra-kit/bootstrap/sync.sh \
    --version test --vendor-dir infra/vendor/infra-kit --source "$KIT_ROOT" 2>&1)"
fi
[[ "$out" == *"vendored infra-kit"* ]] || fail "vendored sync.sh failed: $out"
pass "the vendored sync.sh can replace its own directory"

out="$(cd "$consumer" && make verify-infra-kit 2>&1)" ||
  fail "verify failed after re-syncing: $out"
pass "verify still passes after a self-replacing sync"

# Every path the Makefile names must exist in the vendored payload.
while read -r path; do
  [[ -f "$consumer/$path" ]] || fail "Makefile references a path that was never vendored: $path"
done < <(grep -oE 'infra/vendor/infra-kit/[A-Za-z0-9_./-]+\.sh' "$consumer/Makefile" | sort -u)
pass "every script the Makefile invokes was vendored"

printf 'secret = "%s"\n' "$(secret_token)" > "$consumer/infra/prod.secrets.auto.tfvars"
(cd "$consumer" && make encrypt FILE=infra/prod.secrets.auto.tfvars >/dev/null)
[[ -f "$consumer/infra/prod.secrets.auto.tfvars.enc" ]] ||
  fail "the documented encrypt target did not produce ciphertext"
[[ ! -f "$consumer/infra/prod.secrets.auto.tfvars" ]] ||
  fail "the documented encrypt target left plaintext"
pass "documented make encrypt works from the consumer layout"

export SOPS_AGE_KEY_FILE="$consumer/identity.txt"
before="$(shasum -a 256 "$consumer/infra/prod.secrets.auto.tfvars.enc")"
(cd "$consumer" && SOPS_EDITOR=true make edit FILE=infra/prod.secrets.auto.tfvars >/dev/null)
[[ "$(shasum -a 256 "$consumer/infra/prod.secrets.auto.tfvars.enc")" == "$before" ]] || fail "unchanged edit rewrote ciphertext"
pass "shared make edit preserves unchanged ciphertext"

# Operations hooks must not replace the root-specific validator.
cat > "$consumer/reject" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$consumer/reject"
printf 'operations = "sample"\n' > "$consumer/infra/ops.hcl"
if (cd "$consumer" && make encrypt-ops INFRA_KIT_OPS_PLAINTEXT=infra/ops.hcl \
  INFRA_KIT_OPS_VALIDATE_HOOK="$consumer/reject" >/dev/null 2>&1); then
  fail "operations validation was skipped"
fi
[[ -f "$consumer/infra/ops.hcl" && ! -e "$consumer/infra/ops.hcl.enc" ]] || fail "rejection changed inputs"
(cd "$consumer" && make encrypt-ops INFRA_KIT_OPS_PLAINTEXT=infra/ops.hcl \
  INFRA_KIT_VALIDATE_HOOK="$consumer/reject" >/dev/null)
[[ -f "$consumer/infra/ops.hcl.enc" && ! -e "$consumer/infra/ops.hcl" ]] || fail "ops target inherited root hook"
(cd "$consumer" && SOPS_EDITOR=true make edit-ops INFRA_KIT_OPS_PLAINTEXT=infra/ops.hcl >/dev/null)
pass "shared operations targets use only the operations hook"

printf '\n# drift\n' >> "$consumer/infra/vendor/infra-kit/make/secrets.mk"
if (cd "$consumer" && SOPS_EDITOR=true make edit FILE=infra/prod.secrets.auto.tfvars >/dev/null 2>&1); then
  fail "edit accepted a modified shared Make include"
fi
pass "verification covers the Make include before editing"
