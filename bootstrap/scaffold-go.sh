#!/usr/bin/env bash
set -euo pipefail

# Scaffolds the canonical Go repository baseline: one command writes the same
# six files every Go module carries, so a new library or service starts on the
# shared gate instead of copying the last repository by hand.
#
# Run it from the new repository root, after vendoring the kit:
#
#   bash hack/vendor/infra-kit/bootstrap/scaffold-go.sh \
#     --module github.com/my-org/thing --go 1.24.0 --kit-ref <commit>

usage() {
  cat <<'EOF'
Usage:
  scaffold-go.sh --module PATH --go VERSION --kit-ref SHA
                 [--private-modules a,b] [--test-os '["ubuntu-latest"]']

Writes the Go baseline into the current directory:

  mise.toml                  go pinned to the floor; tasks that call make
  Makefile                   build test lint fmt tools clean
  .golangci.yml              standard linters + errorlint misspell unconvert
                             usetesting; gofumpt formatting
  tools/go.mod               golangci-lint as a tool directive
  .github/workflows/ci.yml   calls infra-kit's reusable Go CI at --kit-ref,
                             plus the `required checks` aggregator
  .github/tidebot.yaml       merge gate on `required checks`
  .gitignore                 created, or appended behind a marker

Refuses to overwrite anything that already exists. --go is the floor go.mod
declares (the same value goes in both). --kit-ref is the infra-kit commit the
reusable workflow is pinned to: a full 40-character SHA, never a tag.
EOF
}

module=""
go_version=""
kit_ref=""
private_modules=""
test_os='["ubuntu-latest", "macos-latest", "windows-latest"]'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) module="$2"; shift 2 ;;
    --go) go_version="$2"; shift 2 ;;
    --kit-ref) kit_ref="$2"; shift 2 ;;
    --private-modules) private_modules="$2"; shift 2 ;;
    --test-os) test_os="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$module" || -z "$go_version" || -z "$kit_ref" ]]; then
  echo "error: --module, --go and --kit-ref are required" >&2
  usage >&2
  exit 1
fi
if [[ ! "$module" =~ ^[a-z0-9.-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  echo "error: --module must be an import path like github.com/org/name" >&2
  exit 1
fi
if [[ ! "$go_version" =~ ^1\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: --go must be a full version like 1.24.0" >&2
  exit 1
fi
if [[ ! "$kit_ref" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: --kit-ref must be a 40-character commit SHA" >&2
  exit 1
fi
if [[ -n "$private_modules" && ! "$private_modules" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
  echo "error: --private-modules is a comma-separated list of repository names" >&2
  exit 1
fi

kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kit_version="v$(head -1 "$kit_dir/VERSION" 2>/dev/null || echo 0.0.0)"

conflicts=()
for path in mise.toml Makefile .golangci.yml tools/go.mod \
  .github/workflows/ci.yml .github/tidebot.yaml; do
  [[ -e "$path" ]] && conflicts+=("$path")
done
if ((${#conflicts[@]})); then
  printf 'error: refusing to overwrite: %s\n' "${conflicts[@]}" >&2
  exit 1
fi

mkdir -p tools .github/workflows

render() {
  local out="$1"
  local sed_args=(
    -e "s|@MODULE@|$module|g"
    -e "s|@GO@|$go_version|g"
    -e "s|@KIT_REF@|$kit_ref|g"
    -e "s|@KIT_VERSION@|$kit_version|g"
    -e "s|@PRIVATE@|$private_modules|g"
    -e "s|@TEST_OS@|$test_os|g"
  )
  if [[ "$out" == - ]]; then
    sed "${sed_args[@]}"
  else
    sed "${sed_args[@]}" >"$out"
  fi
}

render mise.toml <<'TEMPLATE'
# The Go floor this module is developed against: the version go.mod declares,
# not the newest release. A newer local toolchain quietly accepts code a
# consumer on the floor would refuse. CI runs the tests on stable as well.
[tools]
go = "@GO@"

# The Makefile stays the entry point, so these names survive a toolchain change
# and there is one definition of what each check actually runs.
[tasks.build]
description = "Build every package."
run = "make build"

[tasks.test]
description = "Run the full test suite."
run = "make test"

[tasks.lint]
description = "Run the golangci-lint pinned in tools/go.mod."
run = "make lint"

[tasks.fmt]
description = "Apply gofumpt formatting."
run = "make fmt"

[tasks.check]
description = "Build, lint and test — what CI runs."
run = "make check"
TEMPLATE

render Makefile <<'TEMPLATE'
BIN := $(CURDIR)/.bin
GOLANGCI := $(BIN)/golangci-lint

.PHONY: build test lint fmt check tools clean

build:
	go build ./...

test:
	go test ./...

lint: $(GOLANGCI)
	$(GOLANGCI) run

fmt: $(GOLANGCI)
	$(GOLANGCI) fmt

check: build lint test

tools: $(GOLANGCI)

$(GOLANGCI): tools/go.mod tools/go.sum
	GOBIN=$(BIN) go -C tools install tool

clean:
	rm -rf $(BIN)
TEMPLATE

render .golangci.yml <<'TEMPLATE'
version: "2"

linters:
  default: standard
  enable:
    - errorlint
    - misspell
    - unconvert
    - usetesting

formatters:
  enable:
    - gofumpt

issues:
  max-issues-per-linter: 0
  max-same-issues: 0
TEMPLATE

render tools/go.mod <<'TEMPLATE'
module @MODULE@/tools

go @GO@

tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint
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
  # lint at the tools module's floor, tests on stable across the matrix,
  # consumer readiness (race, govulncheck, build at the declared floor).
  baseline:
    uses: fridthjof-labs/infra-kit/.github/workflows/go-ci.yml@@KIT_REF@ # infra-kit @KIT_VERSION@
    with:
      private-modules: '@PRIVATE@'
      test-os: '@TEST_OS@'
    secrets:
      app-id: ${{ secrets.RELEASE_APP_ID }}
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}

  # The one name rulesets and Tidebot gate on. Kept here rather than inside
  # the called workflow, where it would report as "baseline / required checks".
  required-checks:
    name: required checks
    if: always()
    needs: [baseline]
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: check job results
        run: |
          echo "baseline: ${{ needs.baseline.result }}"
          [ "${{ needs.baseline.result }}" = success ]
TEMPLATE

render .github/tidebot.yaml <<'TEMPLATE'
# Tidebot policy for this repository, read by the hosted Tidebot Worker through
# the Tidebot GitHub App installed here.
tide:
  requiredContexts:
    - required checks
TEMPLATE

gitignore_marker="# go baseline (scaffolded)"
if [[ -f .gitignore ]] && grep -Fq "$gitignore_marker" .gitignore; then
  echo "gitignore block already present; leaving .gitignore untouched"
else
  render - <<'TEMPLATE' >>.gitignore
# go baseline (scaffolded)
/.bin/
coverage.out
TEMPLATE
fi

cat <<EOF
scaffolded the Go baseline (module: $module, go: $go_version)

next steps:
  1. go mod init $module        (if go.mod does not exist yet)
  2. go -C tools mod tidy       (writes tools/go.sum for golangci-lint)
  3. mise install && mise run check
  4. commit, push, and install the Tidebot App on the repository
EOF
