#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/tofu.sh
source "${SCRIPT_DIR}/lib/tofu.sh"

usage() {
  cat <<'EOF'
Usage:
  tofu-validate.sh [ROOT ...]

Offline validation of every OpenTofu root (or just the named ones): fmt
-check, a backend-free init against the committed provider lock, and tofu
validate. No credentials, no network beyond the provider cache, no state.

Each root gets a throwaway TF_DATA_DIR so a previously initialized production
backend in .terraform/ cannot leak into an offline check.
EOF
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    -h | --help) usage ;;
  esac
done

infra_kit_require_tofu
tofu_dir="$(infra_kit_tofu_dir)"

roots=("$@")
if [[ ${#roots[@]} -eq 0 ]]; then
  while IFS= read -r root; do
    roots+=("$root")
  done < <(infra_kit_list_roots "$tofu_dir")
fi
if [[ ${#roots[@]} -eq 0 ]]; then
  echo "error: no OpenTofu roots under $tofu_dir" >&2
  exit 1
fi

for root in "${roots[@]}"; do
  infra_kit_require_root_name "$root"
  root_dir="$(infra_kit_root_dir "$tofu_dir" "$root")"
  data_dir="$(mktemp -d "${TMPDIR:-/tmp}/$(infra_kit_tmp_prefix)-tofu-validate.XXXXXX")"
  trap 'rm -rf -- "$data_dir"' EXIT INT TERM HUP
  TF_DATA_DIR="$data_dir" tofu -chdir="$root_dir" fmt -check -recursive
  TF_DATA_DIR="$data_dir" tofu -chdir="$root_dir" init \
    -backend=false -input=false -lockfile=readonly >/dev/null
  TF_DATA_DIR="$data_dir" tofu -chdir="$root_dir" validate
  rm -rf -- "$data_dir"
  trap - EXIT INT TERM HUP
  echo "validated $root"
done
