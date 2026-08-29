#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "tofu-validate"

make_consumer
export INFRA_KIT_TOFU_DIR="$consumer/infra"

mkdir -p "$consumer/stub" "$consumer/infra/site" "$consumer/infra/dns" "$consumer/infra/notaroot"
export TOFU_LOG="$consumer/tofu.log"
cat > "$consumer/stub/tofu" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$TOFU_LOG"
exit 0
EOF
chmod +x "$consumer/stub/tofu"
export PATH="$consumer/stub:$PATH"

echo '# site' > "$consumer/infra/site/main.tf"
echo '# dns' > "$consumer/infra/dns/main.tf"
echo 'not tofu' > "$consumer/infra/notaroot/readme.txt"

validate="$hack/tofu-validate.sh"

: >"$TOFU_LOG"
out="$("$validate" 2>&1)" || fail "validate failed: $out"
for root in site dns; do
  grep -q "/$root fmt -check -recursive" "$TOFU_LOG" || fail "$root was never fmt-checked"
  grep -q "/$root init -backend=false" "$TOFU_LOG" || fail "$root init was not backend-free"
  grep -q "/$root validate" "$TOFU_LOG" || fail "$root was never validated"
done
if grep -q notaroot "$TOFU_LOG"; then
  fail "a directory without .tf files was treated as a root"
fi
grep -q -- '-lockfile=readonly' "$TOFU_LOG" || fail "init may not rewrite the provider lock"
pass "every root is fmt-checked, lock-initialized, and validated"

: >"$TOFU_LOG"
out="$("$validate" site 2>&1)" || fail "single-root validate failed: $out"
if grep -q '/dns ' "$TOFU_LOG"; then
  fail "naming one root still validated the others"
fi
pass "an explicit root narrows the run"

if "$validate" missing >/dev/null 2>&1; then
  fail "a nonexistent root passed validation"
fi
pass "unknown roots fail"
