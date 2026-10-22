#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT
make_consumer

echo "documented encryption quickstart"
awk '/<!-- encryption-quickstart:begin -->/{flag=1;next} /<!-- encryption-quickstart:end -->/{flag=0} flag' \
  "$KIT_ROOT/README.md" | sed '/^```/d' > "$consumer/quickstart.sh"
[[ -s "$consumer/quickstart.sh" ]] || fail "README encryption command is missing"
out="$(cd "$consumer" && bash quickstart.sh)"
[[ "$out" == *'example = "hello"'* ]] || fail "README quickstart did not decrypt the sample"
[[ ! -f "$consumer/infra/example.tfvars" ]] || fail "quickstart left plaintext behind"
pass "README quickstart encrypts and consumes the sample"

awk '/<!-- key-roundtrip:begin -->/{flag=1;next} /<!-- key-roundtrip:end -->/{flag=0} flag' \
  "$KIT_ROOT/docs/encryption-bootstrap.md" | sed '/^```/d' > "$consumer/key-roundtrip.sh"
[[ -s "$consumer/key-roundtrip.sh" ]] || fail "key round-trip command is missing"
AGE_RECIPIENT="$recipient" bash "$consumer/key-roundtrip.sh" >/dev/null || \
  fail "documented SOPS key round trip failed"
pass "documented SOPS key round trip works"
