#!/usr/bin/env bash
set -euo pipefail

# Scaffolds the canonical TypeScript repository baseline: the toolchain pinned
# once in mise.toml, `mise run check` as the definition of done, and a CI
# workflow that calls infra-kit's reusable TS CI so the two never diverge.
#
# Run it from the new repository root, after vendoring the kit:
#
#   bash hack/vendor/infra-kit/bootstrap/scaffold-ts.sh \
#     --node 24.18.0 --pm pnpm --pm-version 11.12.0 --kit-ref <commit>

usage() {
  cat <<'EOF'
Usage:
  scaffold-ts.sh --node VERSION --pm pnpm|bun --pm-version VERSION --kit-ref SHA

Writes the TypeScript baseline into the current directory:

  mise.toml                  node and the package manager pinned; setup and
                             check tasks that call the package scripts
  .github/workflows/ci.yml   calls infra-kit's reusable TS CI at --kit-ref
  .github/tidebot.yaml       merge gate on `ci / check`
  .gitignore                 created, or appended behind a marker

Refuses to overwrite anything that already exists. package.json must define
a `check` script; that is what CI runs. --kit-ref is the infra-kit commit the
reusable workflow is pinned to: a full 40-character SHA, never a tag.
EOF
}

node_version=""
pm=""
pm_version=""
kit_ref=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) node_version="$2"; shift 2 ;;
    --pm) pm="$2"; shift 2 ;;
    --pm-version) pm_version="$2"; shift 2 ;;
    --kit-ref) kit_ref="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$node_version" || -z "$pm" || -z "$pm_version" || -z "$kit_ref" ]]; then
  echo "error: --node, --pm, --pm-version and --kit-ref are required" >&2
  usage >&2
  exit 1
fi
if [[ ! "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$pm_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: versions must be full, like 24.18.0" >&2
  exit 1
fi
case "$pm" in
  pnpm) install_cmd="pnpm install --frozen-lockfile"; run_cmd="pnpm" ;;
  bun) install_cmd="bun install --frozen-lockfile"; run_cmd="bun run" ;;
  *) echo "error: --pm must be pnpm or bun" >&2; exit 1 ;;
esac
if [[ ! "$kit_ref" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: --kit-ref must be a 40-character commit SHA" >&2
  exit 1
fi

kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kit_version="v$(head -1 "$kit_dir/VERSION" 2>/dev/null || echo 0.0.0)"

conflicts=()
for path in mise.toml .github/workflows/ci.yml .github/tidebot.yaml; do
  [[ -e "$path" ]] && conflicts+=("$path")
done
if ((${#conflicts[@]})); then
  printf 'error: refusing to overwrite: %s\n' "${conflicts[@]}" >&2
  exit 1
fi

mkdir -p .github/workflows

render() {
  local out="$1"
  local sed_args=(
    -e "s|@NODE@|$node_version|g"
    -e "s|@PM@|$pm|g"
    -e "s|@PM_VERSION@|$pm_version|g"
    -e "s|@INSTALL@|$install_cmd|g"
    -e "s|@RUN@|$run_cmd|g"
    -e "s|@KIT_REF@|$kit_ref|g"
    -e "s|@KIT_VERSION@|$kit_version|g"
  )
  if [[ "$out" == - ]]; then
    sed "${sed_args[@]}"
  else
    sed "${sed_args[@]}" >"$out"
  fi
}

render mise.toml <<'TEMPLATE'
# Tool pins for this repository. CI installs from here through mise-action, so
# a version is stated once; keep @PM@ equal to package.json's packageManager.
[tools]
node = "@NODE@"
@PM@ = "@PM_VERSION@"

[tasks.setup]
description = "Install dependencies from the committed lockfile."
run = "@INSTALL@"

[tasks.check]
description = "Everything the definition of done requires — what CI runs."
run = "@RUN@ check"
TEMPLATE

render .github/workflows/ci.yml <<'TEMPLATE'
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  # Installs the toolchain from mise.toml and runs `mise run check`.
  ci:
    uses: fridthjof-labs/infra-kit/.github/workflows/ts-ci.yml@@KIT_REF@ # infra-kit @KIT_VERSION@
TEMPLATE

render .github/tidebot.yaml <<'TEMPLATE'
# Tidebot policy for this repository, read by the hosted Tidebot Worker through
# the Tidebot GitHub App installed here.
tide:
  requiredContexts:
    - ci / check
TEMPLATE

gitignore_marker="# ts baseline (scaffolded)"
if [[ -f .gitignore ]] && grep -Fq "$gitignore_marker" .gitignore; then
  echo "gitignore block already present; leaving .gitignore untouched"
else
  render - <<'TEMPLATE' >>.gitignore
# ts baseline (scaffolded)
node_modules/
dist/
TEMPLATE
fi

cat <<EOF
scaffolded the TypeScript baseline (node: $node_version, $pm: $pm_version)

next steps:
  1. add a "check" script to package.json (lint, typecheck, test, build)
  2. mise install && mise run setup && mise run check
  3. commit, push, and install the Tidebot App on the repository
EOF
