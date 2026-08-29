# Shared helpers for the infra-kit encryption scripts.
#
# These scripts are vendored into a consumer repository under .infra-kit/, so
# they must never infer anything from their own location: the original versions
# derived the infrastructure directory from ${BASH_SOURCE[0]}/.., which after
# relocation resolves to .infra-kit/ and looks for .infra-kit/.sops.yaml.
# The consumer states its root explicitly instead.

# shellcheck shell=bash

infra_kit_require_sops() {
  if ! command -v sops >/dev/null 2>&1; then
    echo "error: sops is not installed" >&2
    exit 1
  fi
}

# The directory holding .sops.yaml and the encrypted files.
infra_kit_root() {
  local root="${INFRA_KIT_ROOT:-}"
  if [[ -z "$root" ]]; then
    echo "error: INFRA_KIT_ROOT is not set" >&2
    echo "point it at the directory holding .sops.yaml (the consumer Makefile normally exports it)" >&2
    exit 1
  fi
  if [[ ! -d "$root" ]]; then
    echo "error: INFRA_KIT_ROOT is not a directory: $root" >&2
    exit 1
  fi
  (cd "$root" && pwd)
}

infra_kit_sops_config() {
  local config="${1}/.sops.yaml"
  if [[ ! -f "$config" ]]; then
    echo "error: sops config not found: $config" >&2
    exit 1
  fi
  printf '%s' "$config"
}

infra_kit_tmp_prefix() {
  printf '%s' "${INFRA_KIT_TMP_PREFIX:-infra-kit}"
}

# Selects the age identity and sets INFRA_KIT_AGE_KEY / INFRA_KIT_AGE_KEY_FILE.
# Exactly one is non-empty.
#
# Order: an explicit key, an explicit key file, then the conventional SOPS age
# key file. SOPS_AGE_KEY is read into a variable and unset so it does not reach
# any child process that does not need it.
infra_kit_resolve_age_identity() {
  INFRA_KIT_AGE_KEY="${SOPS_AGE_KEY:-}"
  INFRA_KIT_AGE_KEY_FILE=""

  if [[ -n "$INFRA_KIT_AGE_KEY" ]]; then
    unset SOPS_AGE_KEY
  elif [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
    INFRA_KIT_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE"
  else
    INFRA_KIT_AGE_KEY_FILE="$HOME/.config/sops/age/secure-enclave.txt"
  fi

  if [[ -z "$INFRA_KIT_AGE_KEY" && ! -f "$INFRA_KIT_AGE_KEY_FILE" ]]; then
    echo "error: age identity not found: $INFRA_KIT_AGE_KEY_FILE" >&2
    echo "set SOPS_AGE_KEY_FILE or configure ~/.config/sops/age/secure-enclave.txt" >&2
    exit 1
  fi
}

# Run sops with the resolved identity and an isolated XDG home, so a user's
# own sops config cannot change how a decrypt behaves.
infra_kit_sops_decrypt() {
  local xdg_home="$1"
  local encrypted="$2"

  if [[ -n "$INFRA_KIT_AGE_KEY" ]]; then
    XDG_CONFIG_HOME="$xdg_home" \
      SOPS_AGE_KEY="$INFRA_KIT_AGE_KEY" \
      sops --decrypt "$encrypted"
  else
    XDG_CONFIG_HOME="$xdg_home" \
      SOPS_AGE_KEY_FILE="$INFRA_KIT_AGE_KEY_FILE" \
      sops --decrypt "$encrypted"
  fi
}
