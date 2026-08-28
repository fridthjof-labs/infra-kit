#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  edit-encrypted.sh [encrypted-file]

Defaults:
  encrypted-file = $INFRA_KIT_ROOT/$INFRA_KIT_DEFAULT_SECRETS.enc

Plaintext is opened as a mode-0600 file in a temporary directory. A successful
edit is encrypted back into the original .enc file, and the temporary directory
is removed on every normal exit and handled signal.

Environment:
  INFRA_KIT_ROOT           Directory holding .sops.yaml. Required.
  INFRA_KIT_VALIDATE_HOOK  Executable run against the plaintext before it is
                           re-encrypted. Non-zero aborts and leaves the
                           encrypted file untouched. Repository-specific, so
                           the consumer supplies it.
  SOPS_EDITOR              Editor command. Falls back to EDITOR, then vi.
  SOPS_AGE_KEY             Explicit age identity, primarily for CI or recovery.
  SOPS_AGE_KEY_FILE        Explicit age identity file.
                           Default: ~/.config/sops/age/keys.txt.
EOF
}

infra_kit_require_sops
root="$(infra_kit_root)"
sops_config="$(infra_kit_sops_config "$root")"

encrypted_file="${root}/${INFRA_KIT_DEFAULT_SECRETS:-prod.secrets.auto.tfvars}.enc"
positional=()
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
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
  encrypted_file="${positional[0]}"
fi
if [[ ${#positional[@]} -gt 1 ]]; then
  echo "error: too many positional arguments" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$encrypted_file" && -f "${root}/${encrypted_file}" ]]; then
  encrypted_file="${root}/${encrypted_file}"
fi
if [[ ! -f "$encrypted_file" ]]; then
  echo "error: encrypted file not found: $encrypted_file" >&2
  exit 1
fi
if [[ "$encrypted_file" != *.enc ]]; then
  echo "error: encrypted file must end with .enc: $encrypted_file" >&2
  exit 1
fi

infra_kit_resolve_age_identity
# The editor is a child process and has no need for the identity.
unset SOPS_AGE_KEY_FILE

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/$(infra_kit_tmp_prefix)-sops-edit.XXXXXX")"
plain_file="${tmp_dir}/$(basename "${encrypted_file%.enc}")"
encrypted_output="${tmp_dir}/encrypted-output"
sops_config_home="${tmp_dir}/xdg"
mkdir -m 700 "$sops_config_home"

# shellcheck disable=SC2317,SC2329
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT
# Plaintext lives in $tmp_dir for the duration of the edit, so every path out
# of this script has to remove it — including an interrupted editor.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

infra_kit_sops_decrypt "$sops_config_home" "$encrypted_file" > "$plain_file"
chmod 600 "$plain_file"
unset INFRA_KIT_AGE_KEY

editor="${SOPS_EDITOR:-${EDITOR:-vi}}"
if ! TMPDIR="$tmp_dir" /bin/sh -c "$editor \"\$1\"" sh "$plain_file"; then
  echo "error: editor failed; encrypted file was not changed" >&2
  exit 1
fi

# The schema of a secrets file is the consumer's business, not this toolkit's.
if [[ -n "${INFRA_KIT_VALIDATE_HOOK:-}" ]]; then
  if [[ ! -x "$INFRA_KIT_VALIDATE_HOOK" ]]; then
    echo "error: INFRA_KIT_VALIDATE_HOOK is not executable: $INFRA_KIT_VALIDATE_HOOK" >&2
    exit 1
  fi
  if ! "$INFRA_KIT_VALIDATE_HOOK" "$plain_file"; then
    echo "error: validation failed; encrypted file was not changed" >&2
    exit 1
  fi
fi

# --filename-override keeps the .sops.yaml creation_rules matching on the real
# destination name rather than the temporary one.
sops --config "$sops_config" \
  --filename-override "${encrypted_file%.enc}" \
  --encrypt "$plain_file" > "$encrypted_output"
chmod 600 "$encrypted_output"
mv "$encrypted_output" "$encrypted_file"

echo "encrypted file updated: $encrypted_file"
echo "temporary plaintext removed"
