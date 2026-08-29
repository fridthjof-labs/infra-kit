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

infra_kit_default_age_key_file() {
  case "${INFRA_KIT_PLATFORM:-$(uname -s)}" in
    Darwin*)
      printf '%s' "$HOME/.config/sops/age/secure-enclave.txt"
      ;;
    Linux*)
      printf '%s' "$HOME/.config/sops/age/fido2.txt"
      ;;
    *)
      printf '%s' "$HOME/.config/sops/age/keys.txt"
      ;;
  esac
}

# Selects the age identity and sets INFRA_KIT_AGE_KEY / INFRA_KIT_AGE_KEY_FILE.
# Exactly one is non-empty.
#
# Order: an explicit key, an explicit key file, then the platform default file.
# SOPS_AGE_KEY is read into a variable and unset so it does not reach
# any child process that does not need it.
infra_kit_resolve_age_identity() {
  INFRA_KIT_AGE_KEY="${SOPS_AGE_KEY:-}"
  INFRA_KIT_AGE_KEY_FILE=""

  if [[ -n "$INFRA_KIT_AGE_KEY" ]]; then
    unset SOPS_AGE_KEY
  elif [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
    INFRA_KIT_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE"
  else
    INFRA_KIT_AGE_KEY_FILE="$(infra_kit_default_age_key_file)"
  fi

  if [[ -z "$INFRA_KIT_AGE_KEY" && ! -f "$INFRA_KIT_AGE_KEY_FILE" ]]; then
    echo "error: age identity not found: $INFRA_KIT_AGE_KEY_FILE" >&2
    case "${INFRA_KIT_PLATFORM:-$(uname -s)}" in
      Darwin*)
        echo "set SOPS_AGE_KEY_FILE or create a Secure Enclave identity file" >&2
        ;;
      Linux*)
        echo "set SOPS_AGE_KEY_FILE or create a FIDO2 identity file" >&2
        ;;
      *)
        echo "set SOPS_AGE_KEY_FILE to an age identity file" >&2
        ;;
    esac
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

# The schema of a secrets file is the consumer's business, not this toolkit's,
# so a consumer-supplied hook is the only thing that knows what "valid" means.
# Every path that encrypts plaintext runs it: a first encryption is exactly
# when a missing required key is cheapest to catch.
infra_kit_run_validate_hook() {
  local plaintext="$1"
  local on_failure="$2"
  local hook="${INFRA_KIT_VALIDATE_HOOK:-}"

  [[ -n "$hook" ]] || return 0

  if [[ ! -x "$hook" ]]; then
    echo "error: INFRA_KIT_VALIDATE_HOOK is not executable: $hook" >&2
    exit 1
  fi
  if ! "$hook" "$plaintext"; then
    echo "error: validation failed; $on_failure" >&2
    exit 1
  fi
}

# Content digest, used to tell a real edit from a save that changed nothing.
# Hashing rather than keeping a second copy: the plaintext should exist in
# exactly one place for exactly as long as the editor needs it.
infra_kit_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}
