# Shared helpers for the infra-kit OpenTofu layer.
#
# The encryption scripts stay agnostic about how a repository runs Tofu; these
# helpers are the opposite: they define the one canonical way. A consumer
# declares its layout through environment variables (normally exported by its
# Makefile) and everything else is derived, so two repositories can no longer
# drift apart by hand-copying a driver script.
#
#   INFRA_KIT_ROOT          directory holding .sops.yaml (from lib/common.sh)
#   INFRA_KIT_TOFU_DIR      directory whose subdirectories are OpenTofu roots.
#                           Default: $INFRA_KIT_ROOT.
#   INFRA_KIT_STATE_PREFIX  first segment of every derived state key.
#   INFRA_KIT_OPS_FILE      encrypted operations env file shared by every root.
#                           Default: $INFRA_KIT_TOFU_DIR/ops.env.enc.
#   INFRA_KIT_OPS_HOOK      optional executable validating the sourced ops env.
#   INFRA_KIT_STATE_BACKUP_DIR
#                           where pre-apply state snapshots land.
#                           Default: $INFRA_KIT_TOFU_DIR/../state-backups.
#                           These snapshots are PLAINTEXT OpenTofu state:
#                           provider credentials are stored in state in the
#                           clear. Keep the directory gitignored, and encrypt
#                           a snapshot before it leaves a machine — uploading
#                           one as a CI artifact publishes every secret in it.

# shellcheck shell=bash

infra_kit_require_tofu() {
  if ! command -v tofu >/dev/null 2>&1; then
    echo "error: tofu is not installed" >&2
    exit 1
  fi
}

# The directory whose immediate subdirectories are OpenTofu roots.
infra_kit_tofu_dir() {
  local dir="${INFRA_KIT_TOFU_DIR:-}"
  if [[ -z "$dir" ]]; then
    dir="$(infra_kit_root)"
  fi
  if [[ ! -d "$dir" ]]; then
    echo "error: INFRA_KIT_TOFU_DIR is not a directory: $dir" >&2
    exit 1
  fi
  (cd "$dir" && pwd)
}

# A root is a directory directly under the tofu dir containing .tf files.
# The name is the operator-facing handle: it appears in state keys, backup
# names, and CI inputs, so it stays a plain path-safe word.
infra_kit_require_root_name() {
  local root="$1"
  if [[ ! "$root" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "error: invalid root name: $root" >&2
    exit 1
  fi
}

infra_kit_root_dir() {
  local tofu_dir="$1"
  local root="$2"
  local dir="$tofu_dir/$root"
  if [[ ! -d "$dir" ]] || ! compgen -G "$dir/*.tf" >/dev/null; then
    echo "error: not an OpenTofu root (no .tf files): $dir" >&2
    echo "roots: $(infra_kit_list_roots "$tofu_dir" | tr '\n' ' ')" >&2
    exit 1
  fi
  printf '%s' "$dir"
}

infra_kit_list_roots() {
  local tofu_dir="$1"
  local dir
  for dir in "$tofu_dir"/*/; do
    [[ -d "$dir" ]] || continue
    if compgen -G "${dir}*.tf" >/dev/null; then
      basename "$dir"
    fi
  done
}

# Derived unless the root pins its own. The override file exists for adopted
# roots whose state object predates the convention: renaming a state key means
# migrating a state object, which is never worth it for a name.
infra_kit_state_key() {
  local root_dir="$1"
  local root="$2"
  if [[ -f "$root_dir/state-key" ]]; then
    local key
    key="$(head -1 "$root_dir/state-key")"
    if [[ ! "$key" =~ ^[A-Za-z0-9][A-Za-z0-9/._-]*$ ]]; then
      echo "error: invalid state key in $root_dir/state-key: $key" >&2
      exit 1
    fi
    printf '%s' "$key"
    return
  fi
  local prefix="${INFRA_KIT_STATE_PREFIX:-}"
  if [[ -z "$prefix" ]]; then
    echo "error: INFRA_KIT_STATE_PREFIX is not set" >&2
    echo "the consumer Makefile normally exports it; it is the first segment of every state key" >&2
    exit 1
  fi
  printf '%s/%s/production.tfstate' "$prefix" "$root"
}

# The ops env is the contract between the encrypted operations file and the
# backend: whatever else a repository adds, these four are what state access
# needs. Values still carrying a replace- placeholder count as missing.
infra_kit_require_ops_env() {
  local required=(
    INFRA_KIT_STATE_BUCKET
    INFRA_KIT_STATE_ENDPOINT
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
  )
  local missing=() name value
  for name in "${required[@]}"; do
    value="${!name:-}"
    if [[ -z "$value" || "$value" == replace-* ]]; then
      missing+=("$name")
    fi
  done
  if ((${#missing[@]})); then
    printf 'error: missing operations value: %s\n' "${missing[@]}" >&2
    echo "add it to the encrypted operations file (make edit-ops)" >&2
    exit 1
  fi
  if [[ ! "$INFRA_KIT_STATE_BUCKET" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "error: INFRA_KIT_STATE_BUCKET must be lowercase letters, numbers, and internal hyphens" >&2
    exit 1
  fi
  if [[ ! "$INFRA_KIT_STATE_ENDPOINT" =~ ^https://[^[:space:]]+$ ]]; then
    echo "error: INFRA_KIT_STATE_ENDPOINT must be an https:// URL" >&2
    exit 1
  fi
}

# Written under the root's .terraform/ (never tracked) at init time. Only what
# varies per root and per repository lives here; every invariant backend
# setting belongs in the root's own terraform { backend "s3" { ... } } block
# where it is reviewed like any other code.
infra_kit_write_backend_config() {
  local root_dir="$1"
  local state_key="$2"
  local file="$root_dir/.terraform/backend.hcl"
  umask 077
  mkdir -p "$root_dir/.terraform"
  cat >"$file" <<EOF
bucket = "$INFRA_KIT_STATE_BUCKET"
key    = "$state_key"
endpoints = {
  s3 = "$INFRA_KIT_STATE_ENDPOINT"
}
EOF
  printf '%s' "$file"
}

infra_kit_state_backup_dir() {
  local tofu_dir="$1"
  local dir="${INFRA_KIT_STATE_BACKUP_DIR:-$tofu_dir/../state-backups}"
  mkdir -p "$dir"
  (cd "$dir" && pwd)
}
