#!/usr/bin/env bash
# The single-quoted "$TFVARS" and "$SOPS_AGE_KEY" below are deliberate: they
# expand inside the child shell that with-decrypt.sh runs, which is exactly
# the contract under test. SC2016 would have us break it.
# shellcheck disable=SC2016
set -euo pipefail

# The single-quoted "$TFVARS" and "$SOPS_AGE_KEY" below are deliberate: they
# are expanded inside the child shell that with-decrypt.sh runs, which is
# exactly the contract under test. SC2016 would have us break that.
# shellcheck disable=SC2016
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "edit-encrypted.sh"
make_consumer
token="$(secret_token)"

printf 'secret = "%s-original"\n' "$token" > "$INFRA_KIT_ROOT/prod.secrets.auto.tfvars"
"$hack/encrypt.sh" >/dev/null
enc="$INFRA_KIT_ROOT/prod.secrets.auto.tfvars.enc"

SOPS_EDITOR="sed -i.bak s/-original/-edited/" "$hack/edit-encrypted.sh" >/dev/null
decrypted="$(sops --decrypt "$enc")"
[[ "$decrypted" == *"$token-edited"* ]] || fail "the edit did not round-trip"
pass "round-trips an edit back into the encrypted file"

remaining="$(plaintext_files_containing "$consumer" "$token")"
[[ -z "$remaining" ]] || fail "plaintext left on disk: $remaining"
pass "leaves no plaintext behind after a successful edit"

leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'infra-kit-test-sops-edit.*' 2>/dev/null || true)"
[[ -z "$leftover" ]] || fail "temporary directory survived: $leftover"
pass "removes its temporary directory"

# A refused edit must leave the encrypted file exactly as it was.
before="$(cat "$enc")"
if SOPS_EDITOR="false" "$hack/edit-encrypted.sh" >/dev/null 2>&1; then
  fail "a failing editor reported success"
fi
[[ "$(cat "$enc")" == "$before" ]] || fail "a failing editor changed the encrypted file"
pass "a failing editor leaves the encrypted file untouched"

# The consumer owns the schema; a rejection has to abort the write.
hook="$consumer/validate.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
chmod +x "$hook"
before="$(cat "$enc")"
if INFRA_KIT_VALIDATE_HOOK="$hook" SOPS_EDITOR="sed -i.bak s/-edited/-broken/" \
  "$hack/edit-encrypted.sh" >/dev/null 2>&1; then
  fail "a failing validation hook reported success"
fi
[[ "$(cat "$enc")" == "$before" ]] || fail "a failing hook still wrote the encrypted file"
pass "a rejecting validation hook leaves the encrypted file untouched"

printf '#!/usr/bin/env bash\ngrep -q -- "-edited" "$1"\n' > "$hook"
chmod +x "$hook"
before="$(cat "$enc")"
INFRA_KIT_VALIDATE_HOOK="$hook" SOPS_EDITOR="sed -i.bak s/-edited/-edited2/" \
  "$hack/edit-encrypted.sh" >/dev/null
[[ "$(cat "$enc")" != "$before" ]] || fail "an accepted edit did not reach the file"
[[ "$(sops --decrypt "$enc")" == *"$token-edited2"* ]] ||
  fail "an accepted edit did not round-trip"
pass "an accepting validation hook allows the write"

# sops re-keys on every encryption, so an unconditional re-encrypt would change
# the ciphertext here and make a dropped paste look exactly like a real edit.
before="$(cat "$enc")"
output="$(SOPS_EDITOR="true" "$hack/edit-encrypted.sh")"
[[ "$(cat "$enc")" == "$before" ]] || fail "a no-op edit rewrote the encrypted file"
[[ "$output" == *"unchanged"* ]] || fail "a no-op edit did not say so: $output"
pass "a save that changed nothing leaves the ciphertext byte-identical"

# The hook guards what gets written. With nothing to write there is nothing to
# guard, and a rejecting hook must not fail a save the user did not make.
printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
chmod +x "$hook"
INFRA_KIT_VALIDATE_HOOK="$hook" SOPS_EDITOR="true" "$hack/edit-encrypted.sh" >/dev/null ||
  fail "a no-op edit was rejected by a hook that had nothing to validate"
pass "a no-op edit skips the validation hook"

# An interrupted edit is the case that would otherwise strand plaintext.
SOPS_EDITOR="sleep 30" "$hack/edit-encrypted.sh" >/dev/null 2>&1 &
edit_pid=$!
sleep 2
kill -INT "$edit_pid" 2>/dev/null || true
wait "$edit_pid" 2>/dev/null || true
sleep 1
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'infra-kit-test-sops-edit.*' 2>/dev/null || true)"
[[ -z "$leftover" ]] || fail "interrupted edit stranded plaintext in: $leftover"
pass "an interrupted edit still removes its plaintext"
