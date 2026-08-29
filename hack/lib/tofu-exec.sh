#!/usr/bin/env bash
set -euo pipefail

# The child that with-decrypt.sh hands the FIFOs to. Not an entry point:
# tofu-run.sh is the only caller, and the environment it expects (OPS, and
# optionally OPS_OVERLAY / TFVARS, each naming a one-use FIFO) only exists
# inside that invocation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=lib/tofu.sh
source "${SCRIPT_DIR}/tofu.sh"

[[ $# -ge 3 ]] || {
  echo "error: tofu-exec.sh is internal to tofu-run.sh" >&2
  exit 2
}
root_dir="$1"
root="$2"
action="$3"
shift 3

# The operations env is the whole truth for a run: state backend, provider
# credentials, TF_VAR_* values. Sourcing with set -a exports everything so a
# run never depends on what happened to be exported in the calling shell.
set -a
# shellcheck disable=SC1090
source "$OPS"
if [[ -n "${OPS_OVERLAY:-}" ]]; then
  # shellcheck disable=SC1090
  source "$OPS_OVERLAY"
fi
set +a

infra_kit_require_ops_env

# The kit validated what state access needs; the consumer's hook validates
# what its providers need. The root name lets a hook treat an exceptional
# root differently instead of forking the whole driver.
if [[ -n "${INFRA_KIT_OPS_HOOK:-}" ]]; then
  if [[ ! -x "$INFRA_KIT_OPS_HOOK" ]]; then
    echo "error: INFRA_KIT_OPS_HOOK is not executable: $INFRA_KIT_OPS_HOOK" >&2
    exit 1
  fi
  INFRA_KIT_TOFU_ROOT="$root" "$INFRA_KIT_OPS_HOOK"
fi

tofu_dir="$(infra_kit_tofu_dir)"
state_key="$(infra_kit_state_key "$root_dir" "$root")"
backend_file="$(infra_kit_write_backend_config "$root_dir" "$state_key")"

tofu -chdir="$root_dir" init \
  -backend-config="$backend_file" \
  -input=false \
  -reconfigure >/dev/null
echo "initialized $root with state key $state_key"

if [[ "$action" == backup || ("$action" == apply && "${SKIP_STATE_BACKUP:-0}" != 1) ]]; then
  umask 077
  backup_dir="$(infra_kit_state_backup_dir "$tofu_dir")"
  snapshot="$backup_dir/$root-$(date -u +%Y%m%dT%H%M%SZ).tfstate"
  tofu -chdir="$root_dir" state pull >"$snapshot"
  if [[ ! -s "$snapshot" ]]; then
    rm -f "$snapshot"
    echo "error: state pull returned an empty snapshot" >&2
    echo "a first apply has no state yet: rerun with SKIP_STATE_BACKUP=1" >&2
    exit 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$snapshot" >"$snapshot.sha256"
  else
    sha256sum "$snapshot" >"$snapshot.sha256"
  fi
  echo "state snapshot: $snapshot"
fi

if [[ "$action" == backup ]]; then
  exit 0
fi

args=(-chdir="$root_dir" "$action" -input=false)
if [[ "$action" == apply && "${TOFU_AUTO_APPROVE:-0}" == 1 ]]; then
  args+=(-auto-approve)
fi
if [[ -n "${TFVARS:-}" ]]; then
  args+=(-var-file="$TFVARS")
fi

tofu "${args[@]}" "$@"
