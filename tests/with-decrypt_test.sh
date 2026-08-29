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

echo "with-decrypt.sh"
make_consumer
token="$(secret_token)"

printf 'secret = "%s"\n' "$token" > "$INFRA_KIT_ROOT/prod.secrets.auto.tfvars"
"$hack/encrypt.sh" >/dev/null
enc="$INFRA_KIT_ROOT/prod.secrets.auto.tfvars.enc"

out="$("$hack/with-decrypt.sh" TFVARS="$enc" -- bash -c 'cat "$TFVARS"')"
[[ "$out" == *"$token"* ]] || fail "the command did not receive the plaintext"
pass "streams plaintext to the command"

# The whole point of the FIFO: the secret is never a regular file.
"$hack/with-decrypt.sh" TFVARS="$enc" -- bash -c '
  [[ -p "$TFVARS" ]] || { echo "not a fifo" >&2; exit 1; }
  cat "$TFVARS" >/dev/null
' || fail "the exported path was not a FIFO"
pass "exposes the secret as a FIFO, not a file"

remaining="$(plaintext_files_containing "$consumer" "$token")"
[[ -z "$remaining" ]] || fail "plaintext written to a real file: $remaining"
pass "never writes plaintext to a regular file"

leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'infra-kit-test-decrypt.*' 2>/dev/null || true)"
[[ -z "$leftover" ]] || fail "temporary directory survived: $leftover"
pass "cleans up the FIFO directory"

# A command that never reads the secret is a silent misconfiguration, so it
# must not be reported as success.
if "$hack/with-decrypt.sh" TFVARS="$enc" -- true 2>/dev/null; then
  fail "an unread secret was reported as success"
fi
pass "fails when the command never reads the secret"

if "$hack/with-decrypt.sh" TFVARS="$enc" -- bash -c 'cat "$TFVARS" >/dev/null; exit 7' 2>/dev/null; then
  fail "a failing command was reported as success"
fi
pass "propagates the command's own failure"

# CI supplies the key inline; a workstation supplies a file. Both must work,
# and neither may leak into the child process.
key="$(cat "$SOPS_AGE_KEY_FILE")"
out="$(SOPS_AGE_KEY="$key" SOPS_AGE_KEY_FILE="" "$hack/with-decrypt.sh" \
  TFVARS="$enc" -- bash -c 'cat "$TFVARS"; echo "leaked=${SOPS_AGE_KEY:-no}" >&2' 2>"$consumer/stderr")"
[[ "$out" == *"$token"* ]] || fail "SOPS_AGE_KEY (CI mode) did not decrypt"
grep -q 'leaked=no' "$consumer/stderr" || fail "SOPS_AGE_KEY leaked into the command"
pass "decrypts with an inline key and keeps it out of the command"

out="$("$hack/with-decrypt.sh" TFVARS="$enc" -- bash -c 'cat "$TFVARS"')"
[[ "$out" == *"$token"* ]] || fail "SOPS_AGE_KEY_FILE (local mode) did not decrypt"
pass "decrypts with an explicit key file"

test_home="$consumer/home"
mkdir -p "$test_home/.config/sops/age"
case "$(uname -s)" in
  Darwin*)
    identity_file="secure-enclave.txt"
    ;;
  Linux*)
    identity_file="fido2.txt"
    ;;
  *)
    identity_file="keys.txt"
    ;;
esac

cp "$SOPS_AGE_KEY_FILE" "$test_home/.config/sops/age/$identity_file"
out="$(HOME="$test_home" SOPS_AGE_KEY_FILE="" "$hack/with-decrypt.sh" \
  TFVARS="$enc" -- bash -c 'cat "$TFVARS"')"
[[ "$out" == *"$token"* ]] || fail "the platform-default SOPS age key did not decrypt"
pass "discovers the conventional platform default SOPS age key"

if "$hack/with-decrypt.sh" 'BAD NAME'="$enc" -- true 2>/dev/null; then
  fail "an invalid environment variable name was accepted"
fi
pass "rejects an invalid environment variable name"
