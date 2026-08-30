#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  scan-repo.sh

Offline guard against the ways secret material ends up in a repository. Run
from the consumer repository root (any directory inside its git checkout).
Scans tracked and untracked-but-unignored files for:

  - state, plan, key, and dotenv files that must never be committed
  - credential material in source (private keys, age identities, cloud keys)
  - plaintext twins of the encrypted files (ops.env, *secrets.auto.tfvars,
    backend.*.hcl) -- the .enc file is the only committable form
  - REPLACE_WITH placeholders left over from scaffolding
EOF
  exit 2
}
[[ $# -eq 0 ]] || usage

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

failed=0
while IFS= read -r -d '' path; do
  [[ -f "$path" ]] || continue
  base="$(basename "$path")"
  case "$base" in
    *.tfstate | *.tfstate.* | *.tfplan | .env | .env.* | *.pem | *.key)
      echo "forbidden sensitive or generated file: $path" >&2
      failed=1
      ;;
    ops.env | ops.hcl | secrets.auto.tfvars | *.secrets.auto.tfvars)
      echo "plaintext secret file: $path (only the .enc form is committable)" >&2
      failed=1
      ;;
    backend.*.hcl)
      echo "plaintext backend file: $path (only the .enc form is committable)" >&2
      failed=1
      ;;
  esac
  # A real PEM header stands alone on its line. Anchoring keeps source that
  # merely mentions the marker -- a .replace() that strips it, a comment in an
  # example file -- from being reported: a scanner that cries wolf gets turned
  # off, which is worse than not having one.
  if grep -I -n -E -e \
    '^[[:space:]]*-----BEGIN( [A-Z]+)* PRIVATE KEY-----[[:space:]]*$|AGE-SECRET-KEY-1[0-9A-Z]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}' \
    -- "$path" >/dev/null; then
    echo "potential credential found in source: $path" >&2
    failed=1
  fi
  # Scoped to sops configuration so the check cannot match its own source or
  # documentation that merely mentions the placeholder.
  if [[ "$base" == .sops.yaml ]] && grep -F -q 'REPLACE_WITH' -- "$path"; then
    echo "unfinished scaffold placeholder in: $path" >&2
    failed=1
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

exit "$failed"
