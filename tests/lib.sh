# Test helpers: build a throwaway consumer repository with a real age identity,
# then run the vendored scripts from .infra-kit/hack exactly as a consumer does.
# shellcheck shell=bash

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A value that cannot appear in the toolkit's own source, so a leak scan
# cannot match documentation text instead of an actual secret.
secret_token() {
  printf 'tok-%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok  $*"
}

# Creates $consumer (repo root), $consumer/infra (INFRA_KIT_ROOT) and
# $consumer/.infra-kit/hack (the vendored scripts), and exports the identity.
make_consumer() {
  consumer="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-test.XXXXXX")"
  mkdir -p "$consumer/infra"

  # Vendored exactly as a consumer holds it: an upstream-owned directory
  # nested under infra/hack, which is what broke the location-derived
  # original — it would resolve INFRA_DIR to .../hack/vendor.
  bash "$KIT_ROOT/bootstrap/sync.sh" \
    --version "test" \
    --vendor-dir "$consumer/infra/hack/vendor/infra-kit" \
    --source "$KIT_ROOT" >/dev/null

  age-keygen -o "$consumer/identity.txt" 2>/dev/null
  recipient="$(grep -o 'age1[0-9a-z]*' "$consumer/identity.txt" | head -1)"

  cat > "$consumer/infra/.sops.yaml" <<EOF
creation_rules:
  - path_regex: \.(tfvars|hcl)(\.enc)?\$
    age: ${recipient}
EOF

  export INFRA_KIT_ROOT="$consumer/infra"
  export INFRA_KIT_TMP_PREFIX="infra-kit-test"
  export SOPS_AGE_KEY_FILE="$consumer/identity.txt"
  # Read by the test files that source this helper.
  # shellcheck disable=SC2034
  # Read by the test files that source this helper.
  # shellcheck disable=SC2034
  vendor="$consumer/infra/hack/vendor/infra-kit"
  # shellcheck disable=SC2034
  hack="$vendor/hack"
}

cleanup_consumer() {
  [[ -n "${consumer:-}" ]] && rm -rf -- "$consumer"
}

# Any file under $1 whose contents include $2, ignoring FIFOs.
plaintext_files_containing() {
  find "$1" -type f -exec grep -l -- "$2" {} + 2>/dev/null || true
}
