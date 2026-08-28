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
  --vendor-dir "$consumer/infra/hack/vendor/infra-kit" \
  --source "$KIT_ROOT" >/dev/null
pass "step 1 vendors the payload"

# Step 2: the Makefile is extracted from the documentation itself, so the two
# cannot drift.
awk '/<!-- consumer-makefile:begin -->/{flag=1;next} /<!-- consumer-makefile:end -->/{flag=0} flag' \
  "$KIT_ROOT/docs/consumer.md" | sed '/^```/d' > "$consumer/Makefile"
[[ -s "$consumer/Makefile" ]] || fail "could not extract the Makefile from docs/consumer.md"
grep -q 'sync-hack:' "$consumer/Makefile" || fail "extracted Makefile has no sync-hack target"
pass "step 2 Makefile extracted from the documentation"

# tofu is not part of this toolkit; stub it so `validate` exercises the
# infra-kit half of the documented target.
mkdir -p "$consumer/stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$consumer/stub/tofu"
chmod +x "$consumer/stub/tofu"
export PATH="$consumer/stub:$PATH"

printf '#!/usr/bin/env bash\nexit 0\n' > "$consumer/infra/hack/validate-secrets.sh"
chmod +x "$consumer/infra/hack/validate-secrets.sh"

out="$(cd "$consumer" && make validate 2>&1)" ||
  fail "documented 'make validate' failed: $out"
[[ "$out" == *"verified"* ]] || fail "validate did not verify the vendored payload: $out"
pass "documented 'make validate' runs offline and verifies the payload"

# The target that would have failed before: it invokes the vendored sync.sh,
# which has to replace the very directory it is running from.
out="$(cd "$consumer" && make sync-hack INFRA_KIT_VERSION=test \
  INFRA_KIT_SYNC_SOURCE="$KIT_ROOT" 2>&1)" || true
if [[ "$out" != *"vendored infra-kit"* ]]; then
  # The documented target has no --source, so a network attempt is expected in
  # a sandbox. Drive the vendored script directly to prove self-replacement.
  out="$(cd "$consumer" && bash infra/hack/vendor/infra-kit/bootstrap/sync.sh \
    --version test --vendor-dir infra/hack/vendor/infra-kit --source "$KIT_ROOT" 2>&1)"
fi
[[ "$out" == *"vendored infra-kit"* ]] || fail "vendored sync.sh failed: $out"
pass "the vendored sync.sh can replace its own directory"

out="$(cd "$consumer" && make validate 2>&1)" ||
  fail "validate failed after re-syncing: $out"
pass "validate still passes after a self-replacing sync"

# Every path the Makefile names must exist in the vendored payload.
while read -r path; do
  [[ -f "$consumer/$path" ]] || fail "Makefile references a path that was never vendored: $path"
done < <(grep -oE 'infra/hack/vendor/infra-kit/[A-Za-z0-9_./-]+\.sh' "$consumer/Makefile" | sort -u)
pass "every script the Makefile invokes was vendored"

encrypt_script="$consumer/infra/hack/vendor/infra-kit/hack/encrypt.sh"
printf 'secret = "%s"\n' "$(secret_token)" > "$consumer/infra/prod.secrets.auto.tfvars"
( cd "$consumer" && INFRA_KIT_ROOT="$consumer/infra" SOPS_AGE_KEY_FILE="$consumer/identity.txt" \
  "$encrypt_script" >/dev/null )
[[ -f "$consumer/infra/prod.secrets.auto.tfvars.enc" ]] ||
  fail "the vendored encrypt.sh did not work from the consumer"
pass "the vendored encrypt.sh works from the consumer layout"
