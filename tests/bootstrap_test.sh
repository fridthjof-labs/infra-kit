#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "bootstrap"
make_consumer

lock="$consumer/infra/hack/vendor/infra-kit.lock"

[[ -f "$lock" ]] || fail "sync did not write a lock file"
grep -q '^version = test$' "$lock" || fail "lock does not record the version"
grep -q '^digest = sha256:' "$lock" || fail "lock does not record a digest"
pass "sync records version and digest"

[[ -x "$vendor/hack/encrypt.sh" ]] || fail "vendored scripts are not executable"
pass "vendored scripts stay executable"

# Everything the documented Makefile invokes must actually be installed.
for required in hack/encrypt.sh hack/edit-encrypted.sh hack/with-decrypt.sh \
  hack/lib/common.sh bootstrap/verify.sh bootstrap/sync.sh bootstrap/digest.sh; do
  [[ -f "$vendor/$required" ]] || fail "sync did not vendor $required"
done
pass "vendors hack/ and bootstrap/ as one payload"

bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" >/dev/null
pass "verify accepts freshly vendored files"

# The reason the digest exists: a local edit must not survive silently.
printf '\n# local tweak\n' >> "$vendor/hack/encrypt.sh"
if bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" >/dev/null 2>&1; then
  fail "verify accepted a locally edited vendored file"
fi
message="$(bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" 2>&1 || true)"
[[ "$message" == *"edited locally"* ]] || fail "unhelpful message: $message"
pass "verify rejects a locally edited vendored file, and says why"

bash "$KIT_ROOT/bootstrap/sync.sh" --version test --vendor-dir "$vendor" \
  --source "$KIT_ROOT" >/dev/null
bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" >/dev/null
pass "re-syncing restores a verified state"

# Deleting a file changes the layout, not just content.
rm "$vendor/hack/with-decrypt.sh"
if bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" >/dev/null 2>&1; then
  fail "verify accepted a vendor directory missing a file"
fi
pass "verify rejects a missing vendored file"

rm -rf "$vendor"
message="$(bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" 2>&1 || true)"
[[ "$message" == *"make sync-hack"* ]] || fail "no recovery hint when unvendored: $message"
pass "verify tells you how to recover when nothing is vendored"

# verify must work with no network and no credentials.
message="$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE \
  bash "$KIT_ROOT/bootstrap/sync.sh" --version test --vendor-dir "$vendor" \
  --source "$KIT_ROOT" >/dev/null && \
  env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE \
  bash "$KIT_ROOT/bootstrap/verify.sh" "$vendor" 2>&1)"
[[ "$message" == *"verified"* ]] || fail "verify needed credentials: $message"
pass "verify runs offline and without credentials"
