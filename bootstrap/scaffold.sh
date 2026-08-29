#!/usr/bin/env bash
set -euo pipefail

# Scaffolds the canonical infra-kit OpenTofu consumer: one command turns an
# empty repository into the standard layout, so every new IaC repository
# starts identical instead of hand-copying the last one.
#
# Run it from the consumer repository root, after vendoring the kit:
#
#   bash hack/vendor/infra-kit/bootstrap/scaffold.sh \
#     --state-prefix my-org --root platform

usage() {
  cat <<'EOF'
Usage:
  scaffold.sh --state-prefix PREFIX --root NAME [--tofu-dir DIR]

Writes the canonical consumer layout into the current directory:

  Makefile                        thin facade over the vendored kit
  mise.toml                       local tool pins (opentofu, sops)
  DIR/.sops.yaml                  age recipients (placeholders to replace)
  DIR/ops.env.example             the operations file contract
  DIR/NAME/versions.tf, main.tf   the first OpenTofu root
  .github/workflows/infra.yml    validate on PR/push; gated plan/apply
  .gitignore                      created, or appended behind a marker

Refuses to overwrite anything that already exists. PREFIX is the first
segment of every state key (PREFIX/NAME/production.tfstate); DIR defaults
to tofu.
EOF
}

state_prefix=""
root_name=""
tofu_dir="tofu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-prefix) state_prefix="$2"; shift 2 ;;
    --root) root_name="$2"; shift 2 ;;
    --tofu-dir) tofu_dir="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$state_prefix" || -z "$root_name" ]]; then
  echo "error: --state-prefix and --root are required" >&2
  usage >&2
  exit 1
fi
if [[ ! "$state_prefix" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "error: --state-prefix must be lowercase letters, numbers, hyphens" >&2
  exit 1
fi
if [[ ! "$root_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "error: --root must be a plain lowercase name" >&2
  exit 1
fi
case "$tofu_dir" in
  /* | *..* | "" ) echo "error: --tofu-dir must be a simple relative path" >&2; exit 1 ;;
esac

# The vendor location is wherever this script actually lives, expressed
# relative to the repository root the caller stands in.
kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(pwd)"
if [[ "$kit_dir" != "$repo_dir"/* ]]; then
  echo "error: run scaffold.sh from the repository root that vendors it" >&2
  echo "  kit:  $kit_dir" >&2
  echo "  here: $repo_dir" >&2
  exit 1
fi
vendor_rel="${kit_dir#"$repo_dir"/}"
kit_version="v$(head -1 "$kit_dir/VERSION" 2>/dev/null || echo 0.0.0)"

conflicts=()
for path in \
  Makefile mise.toml \
  "$tofu_dir/.sops.yaml" "$tofu_dir/ops.env.example" \
  "$tofu_dir/$root_name/versions.tf" "$tofu_dir/$root_name/main.tf" \
  .github/workflows/infra.yml; do
  [[ -e "$path" ]] && conflicts+=("$path")
done
if ((${#conflicts[@]})); then
  printf 'error: refusing to overwrite: %s\n' "${conflicts[@]}" >&2
  exit 1
fi

mkdir -p "$tofu_dir/$root_name" .github/workflows

render() {
  local out="$1"
  local sed_args=(
    -e "s|@PREFIX@|$state_prefix|g"
    -e "s|@ROOT@|$root_name|g"
    -e "s|@TOFU_DIR@|$tofu_dir|g"
    -e "s|@VENDOR@|$vendor_rel|g"
    -e "s|@VERSION@|$kit_version|g"
  )
  if [[ "$out" == - ]]; then
    sed "${sed_args[@]}"
  else
    sed "${sed_args[@]}" >"$out"
  fi
}

render Makefile <<'TEMPLATE'
INFRA_KIT         := @VENDOR@
INFRA_KIT_VERSION := @VERSION@

export INFRA_KIT_ROOT         := $(CURDIR)/@TOFU_DIR@
export INFRA_KIT_STATE_PREFIX := @PREFIX@
export INFRA_KIT_TMP_PREFIX   := @PREFIX@

# State operations are per-root: make plan ROOT=@ROOT@.
ROOT ?= @ROOT@

.PHONY: validate plan apply backup encrypt encrypt-ops edit edit-ops sync-hack

# Offline: no network, no credentials.
validate:
	bash $(INFRA_KIT)/bootstrap/verify.sh $(INFRA_KIT)
	bash $(INFRA_KIT)/hack/scan-repo.sh
	bash $(INFRA_KIT)/hack/tofu-validate.sh

plan:
	bash $(INFRA_KIT)/hack/tofu-run.sh $(ROOT) plan

apply:
	bash $(INFRA_KIT)/hack/tofu-run.sh $(ROOT) apply

backup:
	bash $(INFRA_KIT)/hack/tofu-run.sh $(ROOT) backup

encrypt:
	bash $(INFRA_KIT)/hack/encrypt.sh @TOFU_DIR@/$(ROOT)/secrets.auto.tfvars

encrypt-ops:
	bash $(INFRA_KIT)/hack/encrypt.sh @TOFU_DIR@/ops.env

edit:
	bash $(INFRA_KIT)/hack/edit-encrypted.sh @TOFU_DIR@/$(ROOT)/secrets.auto.tfvars.enc

edit-ops:
	bash $(INFRA_KIT)/hack/edit-encrypted.sh @TOFU_DIR@/ops.env.enc

# The only target that reaches the network.
sync-hack:
	bash $(INFRA_KIT)/bootstrap/sync.sh \
	  --version $(INFRA_KIT_VERSION) --vendor-dir $(INFRA_KIT)
TEMPLATE

render mise.toml <<'TEMPLATE'
[tools]
opentofu = "1.12.4"
sops = "3.13.3"
TEMPLATE

render "$tofu_dir/.sops.yaml" <<'TEMPLATE'
# Recipients for every encrypted file in this repository. Three, deliberately:
#   - the operator's hardware identity (Secure Enclave on macOS, FIDO2 on
#     Linux) -- the everyday local decrypt path
#   - this repository's dedicated CI key -- the only identity CI holds, so a
#     leak there cannot decrypt any other repository's secrets
#   - an offline recovery identity -- break-glass only, never in CI
# Replace the placeholders, then re-encrypting any file picks them up.
creation_rules:
  - path_regex: \.(tfvars|hcl|env)$
    age: >-
      REPLACE_WITH_OPERATOR_RECIPIENT,
      REPLACE_WITH_CI_RECIPIENT,
      REPLACE_WITH_RECOVERY_RECIPIENT
TEMPLATE

render "$tofu_dir/ops.env.example" <<'TEMPLATE'
# The shared operations file: sourced (exported) into every plan and apply,
# so a run never depends on what happens to be set in the calling shell.
# Encrypt it with `make encrypt-ops`; the .enc file is the committable form.

# State access -- required by the kit:
INFRA_KIT_STATE_BUCKET=replace-with-state-bucket
INFRA_KIT_STATE_ENDPOINT=replace-with-https-object-store-endpoint
AWS_ACCESS_KEY_ID=replace-with-bucket-scoped-key-id
AWS_SECRET_ACCESS_KEY=replace-with-bucket-scoped-secret

# Provider credentials and TF_VAR_* values shared by every root go here too.
# A credential only one root uses belongs in that root's
# secrets.auto.tfvars.enc instead.
TEMPLATE

render "$tofu_dir/$root_name/versions.tf" <<'TEMPLATE'
terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  # Everything invariant lives here in review; only bucket, key, and endpoint
  # vary, and the kit supplies those at init from the operations file.
  backend "s3" {
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = true
    use_path_style              = true
  }
}
TEMPLATE

render "$tofu_dir/$root_name/main.tf" <<'TEMPLATE'
# Root @ROOT@. State key: @PREFIX@/@ROOT@/production.tfstate.
TEMPLATE

render .github/workflows/infra.yml <<'TEMPLATE'
name: Infrastructure

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      operation:
        description: OpenTofu operation
        required: true
        default: plan
        type: choice
        options:
          - plan
          - apply
      root:
        description: OpenTofu root
        required: true
        default: '@ROOT@'
        type: string

permissions:
  contents: read

concurrency:
  # Two runs must never mutate the same remote state concurrently.
  group: infra-${{ github.ref }}
  cancel-in-progress: false

jobs:
  validate:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.12.4
          tofu_wrapper: false
      - run: make validate

  plan:
    name: plan (${{ inputs.root }})
    if: github.event_name == 'workflow_dispatch' && inputs.operation == 'plan'
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    environment: Production
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.12.4
          tofu_wrapper: false
      - uses: mdgreenwald/mozilla-sops-action@55177c1ff20a2b396280e4c5f53c32b69f0c1e40 # v2.1.1
        with:
          version: 3.13.3
      - env:
          SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
        run: make plan ROOT="${{ inputs.root }}"

  apply:
    name: apply (${{ inputs.root }})
    if: >-
      github.event_name == 'workflow_dispatch' &&
      inputs.operation == 'apply' &&
      github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    environment: Production
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.12.4
          tofu_wrapper: false
      - uses: mdgreenwald/mozilla-sops-action@55177c1ff20a2b396280e4c5f53c32b69f0c1e40 # v2.1.1
        with:
          version: 3.13.3
      - env:
          SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
          TOFU_AUTO_APPROVE: '1'
        run: make apply ROOT="${{ inputs.root }}"
TEMPLATE

gitignore_marker="# infra-kit (scaffolded)"
if [[ -f .gitignore ]] && grep -Fq "$gitignore_marker" .gitignore; then
  echo "gitignore block already present; leaving .gitignore untouched"
else
  render - <<'TEMPLATE' >>.gitignore
# infra-kit (scaffolded)
.terraform/
**/.terraform/
*.tfstate
*.tfstate.*
*.tfplan
state-backups/
@TOFU_DIR@/ops.env
@TOFU_DIR@/*/ops.env
@TOFU_DIR@/*/secrets.auto.tfvars
TEMPLATE
fi

cat <<EOF
scaffolded the canonical layout (state prefix: $state_prefix, root: $root_name)

next steps:
  1. replace the three REPLACE_WITH recipients in $tofu_dir/.sops.yaml
     (docs/encryption-bootstrap.md covers creating the identities)
  2. create the state bucket and a bucket-scoped access key, then:
       cp $tofu_dir/ops.env.example $tofu_dir/ops.env
       edit it, then: make encrypt-ops
  3. set the repository's Production environment secret SOPS_AGE_KEY to the
     dedicated CI identity
  4. make validate, then the first apply:
       SKIP_STATE_BACKUP=1 make apply ROOT=$root_name
EOF
