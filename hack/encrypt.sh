#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  encrypt.sh [input-file] [output-file] [--keep-input]

Defaults:
  input-file  = $INFRA_KIT_ROOT/$INFRA_KIT_DEFAULT_SECRETS
  output-file = <input-file>.enc

Examples:
  encrypt.sh
  encrypt.sh prod.secrets.auto.tfvars
  encrypt.sh backend.prod.hcl backend.prod.hcl.enc
  encrypt.sh backend.prod.hcl --keep-input

Recipients come from $INFRA_KIT_ROOT/.sops.yaml (creation_rules), not from any
local age identity file — encryption only ever needs the recipient's public key.

Environment:
  INFRA_KIT_ROOT             Directory holding .sops.yaml. Required.
  INFRA_KIT_DEFAULT_SECRETS  Default input file name.
  INFRA_KIT_VALIDATE_HOOK    Executable run against the plaintext before it is
                             encrypted. Non-zero aborts, leaving both the input
                             and any existing .enc untouched. Repository-specific,
                             so the consumer supplies it.
  KEEP_PLAINTEXT_SECRETS     Set to 1 to keep the plaintext input.
EOF
}

infra_kit_require_sops
root="$(infra_kit_root)"
sops_config="$(infra_kit_sops_config "$root")"

input_file="${root}/${INFRA_KIT_DEFAULT_SECRETS:-prod.secrets.auto.tfvars}"
output_file=""
keep_input="${KEEP_PLAINTEXT_SECRETS:-0}"

positional=()
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    --keep-input)
      keep_input="1"
      ;;
    --*)
      echo "error: unknown flag: $arg" >&2
      usage >&2
      exit 1
      ;;
    *)
      positional+=("$arg")
      ;;
  esac
done

if [[ ${#positional[@]} -ge 1 ]]; then
  input_file="${positional[0]}"
fi
if [[ ${#positional[@]} -ge 2 ]]; then
  output_file="${positional[1]}"
fi
if [[ ${#positional[@]} -gt 2 ]]; then
  echo "error: too many positional arguments" >&2
  usage >&2
  exit 1
fi

# A bare name is resolved against the consumer root, so callers can say
# `encrypt.sh backend.prod.hcl` from anywhere.
if [[ ! -f "$input_file" && -f "${root}/${input_file}" ]]; then
  input_file="${root}/${input_file}"
  if [[ ${#positional[@]} -lt 2 ]]; then
    output_file=""
  fi
fi

if [[ -z "$output_file" ]]; then
  output_file="${input_file}.enc"
fi

if [[ ! -f "$input_file" ]]; then
  echo "error: input file not found: $input_file" >&2
  exit 1
fi

# Before anything is written or removed: a rejected input must leave both the
# plaintext and any existing .enc exactly as they were.
infra_kit_run_validate_hook "$input_file" "nothing was encrypted"

# Encrypt to a temporary file first: a failed sops run must not leave a
# truncated .enc where a valid one used to be.
umask 077
tmp_output="$(mktemp "${TMPDIR:-/tmp}/$(infra_kit_tmp_prefix)-encrypt.XXXXXX")"
trap 'rm -f "$tmp_output"' EXIT

sops --config "$sops_config" \
  --filename-override "$input_file" \
  --encrypt "$input_file" > "$tmp_output"
chmod 600 "$tmp_output"
mv "$tmp_output" "$output_file"

echo "encrypted: $output_file"
echo "sops config: $sops_config"

if [[ "$keep_input" != "1" && "$input_file" != "$output_file" ]]; then
  rm -f "$input_file"
  echo "removed plaintext: $input_file"
fi
