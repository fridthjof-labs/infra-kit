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

# The consumer Makefile in docs/consumer.md exports INFRA_KIT_VALIDATE_HOOK for
# every target, so encrypt.sh silently ignoring it was a safety control that
# looked wired and was not.
hook="$consumer/validate.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
chmod +x "$hook"
printf 'incomplete = "1"\n' > "$INFRA_KIT_ROOT/hooked.hcl"
if INFRA_KIT_VALIDATE_HOOK="$hook" "$hack/encrypt.sh" hooked.hcl >/dev/null 2>&1; then
  fail "a rejecting validation hook reported success"
fi
[[ ! -f "$INFRA_KIT_ROOT/hooked.hcl.enc" ]] || fail "a rejected input was still encrypted"
[[ -f "$INFRA_KIT_ROOT/hooked.hcl" ]] || fail "a rejected input was consumed anyway"
pass "a rejecting validation hook encrypts nothing and keeps the input"

# "$1" is the hook's own argument and must reach it unexpanded.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ngrep -q incomplete "$1"\n' > "$hook"
chmod +x "$hook"
INFRA_KIT_VALIDATE_HOOK="$hook" "$hack/encrypt.sh" hooked.hcl >/dev/null
[[ -f "$INFRA_KIT_ROOT/hooked.hcl.enc" ]] || fail "an accepted input was not encrypted"
pass "an accepting validation hook allows the encryption"

# The consumer's hook describes the consumer's secrets. A Makefile exports it
# for every target, so encrypting the toolkit's own ops.env must not send it
# through a tfvars schema check -- that is what left a consumer with no
# operations file at all.
printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
chmod +x "$hook"
printf 'INFRA_KIT_STATE_BUCKET=state\nAWS_SECRET_ACCESS_KEY=%s\n' "$token" \
  > "$INFRA_KIT_ROOT/ops.env"
INFRA_KIT_VALIDATE_HOOK="$hook" "$hack/encrypt.sh" ops.env >/dev/null ||
  fail "ops.env was rejected by the consumer's secrets hook"
[[ -f "$INFRA_KIT_ROOT/ops.env.enc" ]] || fail "ops.env was not encrypted"
[[ ! -f "$INFRA_KIT_ROOT/ops.env" ]] || fail "plaintext ops.env survived encryption"
pass "ops.env bypasses the consumer's secrets hook"

printf 'INFRA_KIT_STATE_BUCKET=state\nif\n' > "$INFRA_KIT_ROOT/ops.env"
if "$hack/encrypt.sh" ops.env "$INFRA_KIT_ROOT/broken.env.enc" >/dev/null 2>&1; then
  fail "an unparseable ops.env was encrypted"
fi
rm "$INFRA_KIT_ROOT/ops.env"
pass "an ops.env that does not parse is refused"

printf 'more = "1"\n' > "$INFRA_KIT_ROOT/unreadable.hcl"
error_text="$(INFRA_KIT_VALIDATE_HOOK="$consumer/not-a-hook" \
  "$hack/encrypt.sh" unreadable.hcl 2>&1 || true)"
[[ "$error_text" == *"not executable"* ]] ||
  fail "an unusable hook produced an unhelpful error: $error_text"
pass "names an INFRA_KIT_VALIDATE_HOOK that cannot be run"
