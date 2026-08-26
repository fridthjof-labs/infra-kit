#!/usr/bin/env bash
set -euo pipefail

# Offline check that the committed vendored files still match the lock.
# Reaches no network, reads no credentials, so it belongs in `make validate`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=digest.sh
source "${SCRIPT_DIR}/digest.sh"

vendor_dir="${1:-}"
if [[ -z "$vendor_dir" ]]; then
  echo "usage: verify.sh VENDOR_DIR" >&2
  exit 1
fi

lock="$(dirname "$vendor_dir")/infra-kit.lock"

if [[ ! -d "$vendor_dir" ]]; then
  echo "error: vendored infra-kit not found: $vendor_dir" >&2
  echo "run: make sync-hack" >&2
  exit 1
fi
if [[ ! -f "$lock" ]]; then
  echo "error: lock file not found: $lock" >&2
  echo "run: make sync-hack" >&2
  exit 1
fi

expected="$(sed -n 's/^digest = sha256:\(.*\)$/\1/p' "$lock" | head -1)"
version="$(sed -n 's/^version = \(.*\)$/\1/p' "$lock" | head -1)"

if [[ -z "$expected" ]]; then
  echo "error: no digest recorded in $lock" >&2
  exit 1
fi

actual="$(infra_kit_tree_digest "$vendor_dir")"

if [[ "$actual" != "$expected" ]]; then
  echo "error: vendored infra-kit does not match ${lock}" >&2
  echo "  expected sha256:${expected}" >&2
  echo "  actual   sha256:${actual}" >&2
  echo "a vendored file was edited locally; re-run make sync-hack or revert it" >&2
  exit 1
fi

echo "infra-kit ${version} verified (sha256:${actual})"
