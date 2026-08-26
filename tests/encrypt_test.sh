#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "encrypt.sh"
make_consumer
token="$(secret_token)"

# The regression this port exists for: vendored scripts live at
# infra/hack/vendor/infra-kit, so deriving the root from their own location
# resolves to .../hack/vendor and looks for the wrong .sops.yaml.
# INFRA_KIT_ROOT is what makes relocation safe.
printf 'secret = "%s"\n' "$token" > "$INFRA_KIT_ROOT/prod.secrets.auto.tfvars"
"$hack/encrypt.sh" >/dev/null
[[ -f "$INFRA_KIT_ROOT/prod.secrets.auto.tfvars.enc" ]] ||
  fail "encrypt did not produce the .enc file from a vendored location"
pass "runs from a vendored directory against the consumer root"

[[ ! -f "$INFRA_KIT_ROOT/prod.secrets.auto.tfvars" ]] ||
  fail "plaintext input survived encryption"
pass "removes the plaintext input by default"

remaining="$(plaintext_files_containing "$consumer" "$token")"
[[ -z "$remaining" ]] || fail "plaintext left on disk: $remaining"
pass "leaves no plaintext anywhere under the consumer"

grep -q "ENC\[" "$INFRA_KIT_ROOT/prod.secrets.auto.tfvars.enc" ||
  fail "output does not look encrypted"
pass "output is sops-encrypted"

# Without the explicit root there is nothing to guess from; it must say so.
( unset INFRA_KIT_ROOT
  if "$hack/encrypt.sh" 2>/dev/null; then exit 1; fi ) ||
  fail "encrypt.sh succeeded without INFRA_KIT_ROOT"
error_text="$(unset INFRA_KIT_ROOT; "$hack/encrypt.sh" 2>&1 || true)"
[[ "$error_text" == *"INFRA_KIT_ROOT is not set"* ]] ||
  fail "unhelpful error without INFRA_KIT_ROOT: $error_text"
pass "fails with a nameable error when the consumer root is unset"

printf 'other = "kept"\n' > "$INFRA_KIT_ROOT/backend.prod.hcl"
"$hack/encrypt.sh" backend.prod.hcl --keep-input >/dev/null
[[ -f "$INFRA_KIT_ROOT/backend.prod.hcl" ]] || fail "--keep-input removed the input"
[[ -f "$INFRA_KIT_ROOT/backend.prod.hcl.enc" ]] || fail "--keep-input produced no output"
pass "--keep-input keeps the plaintext and still encrypts"

# A failing encrypt must not destroy the good .enc that is already there.
before="$(cat "$INFRA_KIT_ROOT/backend.prod.hcl.enc")"
printf 'x\n' > "$INFRA_KIT_ROOT/broken.hcl"
mv "$INFRA_KIT_ROOT/.sops.yaml" "$INFRA_KIT_ROOT/.sops.yaml.bak"
"$hack/encrypt.sh" broken.hcl "$INFRA_KIT_ROOT/backend.prod.hcl.enc" >/dev/null 2>&1 || true
mv "$INFRA_KIT_ROOT/.sops.yaml.bak" "$INFRA_KIT_ROOT/.sops.yaml"
[[ "$(cat "$INFRA_KIT_ROOT/backend.prod.hcl.enc")" == "$before" ]] ||
  fail "a failed encrypt overwrote an existing .enc"
pass "a failed encrypt leaves the existing .enc intact"
