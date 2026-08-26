#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  with-decrypt.sh NAME=path/to/file.enc [NAME=path/to/other.enc ...] -- command [args...]

Example:
  with-decrypt.sh \
    TFVARS=infra/prod.secrets.auto.tfvars.enc \
    BACKEND=infra/backend.prod.hcl.enc \
    -- \
    bash -lc 'tofu init -reconfigure -backend-config="$BACKEND" && tofu apply -var-file="$TFVARS"'

Each NAME becomes an environment variable pointing to a temporary FIFO.
Plaintext is streamed to the command and never written to a regular file.

Local key selection:
  1. SOPS_AGE_KEY or SOPS_AGE_KEY_FILE, when explicitly set
  2. ~/.config/sops/age/secure-enclave.txt (Touch ID)
EOF
}

infra_kit_require_sops

pairs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      break
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *=*)
      pairs+=("$1")
      shift
      ;;
    *)
      echo "error: expected NAME=encrypted-file or --, got: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${#pairs[@]} -eq 0 ]]; then
  echo "error: no encrypted files provided" >&2
  usage >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "error: no command provided" >&2
  usage >&2
  exit 1
fi

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/$(infra_kit_tmp_prefix)-decrypt.XXXXXX")"
sops_config_home="${tmp_dir}/xdg"
mkdir -m 700 "$sops_config_home"
decrypt_pids=()

# cleanup is reached only through the traps below. Older shellcheck reports
# SC2317 on the body, newer SC2329 on the name; disable both so the check does
# not depend on the runner's shellcheck version.
# shellcheck disable=SC2317,SC2329
cleanup() {
  if ((${#decrypt_pids[@]} > 0)); then
    kill "${decrypt_pids[@]}" 2>/dev/null || true
    wait "${decrypt_pids[@]}" 2>/dev/null || true
  fi
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT
# Without these, an interrupt would leave the FIFOs and the writer processes
# behind, still holding decrypted material.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

infra_kit_resolve_age_identity

for pair in "${pairs[@]}"; do
  name="${pair%%=*}"
  enc_path="${pair#*=}"

  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "error: invalid environment variable name: $name" >&2
    exit 1
  fi

  if [[ ! -f "$enc_path" ]]; then
    echo "error: encrypted file not found: $enc_path" >&2
    exit 1
  fi

  fifo="${tmp_dir}/${name}"
  mkfifo -m 600 "$fifo"
  (infra_kit_sops_decrypt "$sops_config_home" "$enc_path" > "$fifo") &
  decrypt_pids+=("$!")
  export "$name=$fifo"
done

set +e
"$@"
command_status=$?
set -e

# A writer still running means the command never read that FIFO — the secret
# was not consumed, which is a failure even if the command exited zero.
decrypt_status=0
running_pids="$(jobs -pr)"
for pid in "${decrypt_pids[@]}"; do
  writer_running=0
  for running_pid in $running_pids; do
    if [[ "$running_pid" == "$pid" ]]; then
      writer_running=1
      break
    fi
  done

  if ((writer_running)); then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    decrypt_status=1
  elif ! wait "$pid"; then
    decrypt_status=1
  fi
done
decrypt_pids=()

if ((command_status != 0)); then
  exit "$command_status"
fi
exit "$decrypt_status"
