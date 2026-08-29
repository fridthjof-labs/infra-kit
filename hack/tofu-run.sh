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
  tofu-run.sh ROOT plan   [extra tofu args...]
  tofu-run.sh ROOT apply  [extra tofu args...]
  tofu-run.sh ROOT import ADDRESS ID
  tofu-run.sh ROOT backup

The one way a consumer runs OpenTofu against production state. Every action:

  1. decrypts the shared operations file (and the root's ops.env.enc overlay,
     when one exists) through one-use FIFOs -- plaintext never touches disk
  2. validates the ops contract, then the consumer's INFRA_KIT_OPS_HOOK
  3. writes the backend config for the root's derived state key and runs
     tofu init -reconfigure
  4. apply additionally pulls a state snapshot first (R2 has no bucket
     versioning); backup does only that and stops

Per-root files, all optional:
  secrets.auto.tfvars.enc   root-scoped secret variables, streamed as -var-file
  ops.env.enc               overlay sourced after the shared operations file
  state-key                 pins a pre-convention state key for adopted roots

Environment:
  INFRA_KIT_ROOT / INFRA_KIT_TOFU_DIR / INFRA_KIT_STATE_PREFIX /
  INFRA_KIT_OPS_FILE / INFRA_KIT_OPS_HOOK   layout, see lib/tofu.sh
  SOPS_AGE_KEY / SOPS_AGE_KEY_FILE          age identity (CI sets the former)
  TOFU_AUTO_APPROVE=1   apply without interactive confirmation (CI)
  SKIP_STATE_BACKUP=1   only for a root's very first apply, when there is no
                        state object to snapshot yet
EOF
  exit 2
}

[[ $# -ge 2 ]] || usage
root="$1"
action="$2"
shift 2

case "$action" in
  plan | apply | backup) ;;
  import)
    [[ $# -eq 2 ]] || usage
    ;;
  *) usage ;;
esac

infra_kit_require_tofu
infra_kit_require_sops
infra_kit_require_root_name "$root"

tofu_dir="$(infra_kit_tofu_dir)"
root_dir="$(infra_kit_root_dir "$tofu_dir" "$root")"

# A committed plaintext secrets.auto.tfvars would be auto-loaded by tofu and
# silently win over the encrypted file. Refuse ambiguous input.
if [[ -f "$root_dir/secrets.auto.tfvars" ]]; then
  echo "error: plaintext $root_dir/secrets.auto.tfvars exists" >&2
  echo "encrypt it with encrypt.sh, then delete the plaintext" >&2
  exit 1
fi

ops_file="${INFRA_KIT_OPS_FILE:-$tofu_dir/ops.env.enc}"
if [[ ! -f "$ops_file" ]]; then
  echo "error: operations file not found: $ops_file" >&2
  echo "create it from ops.env.example with encrypt.sh, or point INFRA_KIT_OPS_FILE at it" >&2
  exit 2
fi

pairs=("OPS=$ops_file")
if [[ -f "$root_dir/ops.env.enc" && "$root_dir/ops.env.enc" != "$ops_file" ]]; then
  pairs+=("OPS_OVERLAY=$root_dir/ops.env.enc")
fi
if [[ "$action" != backup && -f "$root_dir/secrets.auto.tfvars.enc" ]]; then
  pairs+=("TFVARS=$root_dir/secrets.auto.tfvars.enc")
fi

# One with-decrypt invocation carries every FIFO the run needs; tofu-exec.sh
# is the child that consumes them.
exec "${SCRIPT_DIR}/with-decrypt.sh" "${pairs[@]}" -- \
  bash "${SCRIPT_DIR}/lib/tofu-exec.sh" "$root_dir" "$root" "$action" "$@"
