#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "scan-repo"

make_consumer
scan="$hack/scan-repo.sh"

# The consumer is a real git repository; the identity file sits inside it, so
# the very first scan proves the age-key detection on realistic content.
git -C "$consumer" init -q
if (cd "$consumer" && "$scan") >/dev/null 2>&1; then
  fail "an age identity in the checkout passed the scan"
fi
pass "an unignored age identity fails the scan"

echo 'identity.txt' > "$consumer/.gitignore"
out="$(cd "$consumer" && "$scan" 2>&1)" ||
  fail "a clean consumer failed the scan (the vendored kit tripped itself?): $out"
pass "a clean consumer passes, vendored kit included"

check_fails() {
  local label="$1"
  if (cd "$consumer" && "$scan") >/dev/null 2>&1; then
    fail "$label passed the scan"
  fi
  pass "$label fails the scan"
}

echo '{}' > "$consumer/prod.tfstate"
check_fails "a state file"
rm -f "$consumer/prod.tfstate"

printf 'aws = "%s%s"\n' AKIA 'ABCDEFGHIJKLMNOP' > "$consumer/infra/leak.tf"
check_fails "an embedded cloud key"
rm -f "$consumer/infra/leak.tf"

printf 'token = "x"\n' > "$consumer/infra/prod.secrets.auto.tfvars"
check_fails "a plaintext secrets file"
rm -f "$consumer/infra/prod.secrets.auto.tfvars"

printf 'INFRA_KIT_STATE_BUCKET=b\n' > "$consumer/infra/ops.env"
check_fails "a plaintext operations file"
rm -f "$consumer/infra/ops.env"

printf 'bucket = "b"\n' > "$consumer/infra/backend.prod.hcl"
check_fails "a plaintext backend file"
rm -f "$consumer/infra/backend.prod.hcl"

sed -i.bak 's/age: .*/age: REPLACE_WITH_OPERATOR_RECIPIENT/' "$consumer/infra/.sops.yaml" &&
  rm -f "$consumer/infra/.sops.yaml.bak"
check_fails "a scaffold placeholder left in .sops.yaml"

# The placeholder case above left .sops.yaml deliberately broken; restore it
# so the next cases fail for their own reason or not at all.
cat > "$consumer/infra/.sops.yaml" <<EOF
creation_rules:
  - path_regex: \.(tfvars|hcl|env)\$
    age: $(grep -o 'age1[0-9a-z]*' "$consumer/identity.txt" | head -1)
EOF

# A marker that is merely referenced is not a finding: app code that strips a
# PEM header, or an example file documenting one, must not fail the scan.
printf 'const stripped = pem.replace("-----BEGIN PRIVATE KEY-----", "");\n' \
  > "$consumer/app.ts"
printf '# paste the key, including the\n#   -----BEGIN PRIVATE KEY-----\n# line\n' \
  > "$consumer/infra/secrets.example.tfvars"
out="$(cd "$consumer" && "$scan" 2>&1)" ||
  fail "a referenced PEM marker was reported as a credential: $out"
pass "a referenced PEM marker is not a finding"

# A pasted key still is: its header stands alone on the line.
printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkq\n-----END PRIVATE KEY-----\n' \
  > "$consumer/leaked.pem.txt"
check_fails "a pasted private key"
rm -f "$consumer/leaked.pem.txt" "$consumer/app.ts" "$consumer/infra/secrets.example.tfvars"
