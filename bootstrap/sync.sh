#!/usr/bin/env bash
set -euo pipefail

# Fetches a pinned infra-kit release into a consumer's vendor directory and
# records version and digest in infra-kit.lock.
#
# This is the only command that reaches the network. `validate`, `plan`, and
# `apply` verify the committed bytes offline against the lock and never
# download anything — an upgrade is a reviewed commit, not a side effect.

usage() {
  cat <<'EOF'
Usage:
  sync.sh --version VERSION --vendor-dir DIR [--repo OWNER/NAME] [--source PATH]

Downloads infra-kit VERSION and replaces DIR with its vendored payload
(hack/, bootstrap/, VERSION), then writes DIR.lock recording version and digest.
DIR must end in infra-kit so a typo cannot replace a broader directory.

  --source PATH   Vendor from a local checkout instead of downloading.

The download is a plain anonymous curl of the tag archive. A private repository
or fork returns 404 to that, so it falls back to an authenticated `gh`.
EOF
}

version=""
vendor_dir=""
repo="fridthjof-labs/infra-kit"
source_path=""

args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --vendor-dir) vendor_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --source) source_path="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$version" || -z "$vendor_dir" ]]; then
  echo "error: --version and --vendor-dir are required" >&2
  usage >&2
  exit 1
fi

if [[ "$(basename "${vendor_dir%/}")" != "infra-kit" ]]; then
  echo "error: --vendor-dir must end in infra-kit: $vendor_dir" >&2
  exit 1
fi

mkdir -p "$(dirname "$vendor_dir")"
vendor_abs="$(cd "$(dirname "$vendor_dir")" && pwd)/$(basename "$vendor_dir")"
script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The vendored copy of this script lives inside the directory it is about to
# replace. Bash reads a script incrementally, so deleting the file mid-run
# truncates execution — re-exec from a copy outside the blast radius first.
if [[ "${INFRA_KIT_SYNC_REEXEC:-}" != "1" && "$script_abs" == "$vendor_abs"/* ]]; then
  relay="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-sync-self.XXXXXX")"
  trap 'rm -rf -- "$relay"' EXIT
  cp -R "$script_abs/." "$relay/"
  INFRA_KIT_SYNC_REEXEC=1 exec bash "$relay/$(basename "${BASH_SOURCE[0]}")" "${args[@]}"
fi

# This file is the trust bootstrap: consumers download it before any other
# infra-kit file exists. Keep the digest implementation self-contained here;
# the vendored verify.sh uses bootstrap/digest.sh for offline checks.
infra_kit_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

infra_kit_tree_digest() {
  local dir="$1"
  (
    cd "$dir" || exit 1
    find . -type f -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        printf '%s  %s\n' "$(infra_kit_sha256 < "$file")" "${file#./}"
      done
  ) | infra_kit_sha256
}

umask 077
staging="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-sync.XXXXXX")"
cleanup_staging() { rm -rf -- "$staging"; }
trap cleanup_staging EXIT

# Public releases are a plain anonymous download; gh is the fallback that still
# reaches a private repository or a private fork.
download_archive() {
  local dest="$1"
  local url="https://github.com/${repo}/archive/refs/tags/${version}.tar.gz"

  if curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$dest"; then
    return 0
  fi

  if command -v gh >/dev/null 2>&1 &&
    gh api "repos/${repo}/tarball/${version}" > "$dest" 2>"${staging}/gh.err"; then
    return 0
  fi

  echo "error: could not download ${repo}@${version}" >&2
  echo "  tried ${url}" >&2
  if [[ -s "${staging}/gh.err" ]]; then
    sed 's/^/  /' "${staging}/gh.err" >&2
  fi
  echo "a private repository or fork needs an authenticated gh: gh auth login" >&2
  return 1
}

extracted=""
if [[ -n "$source_path" ]]; then
  extracted="${source_path%/}"
else
  archive="${staging}/infra-kit.tar.gz"
  download_archive "$archive"

  # Unpack into a child directory. The staging directory is itself named
  # infra-kit-sync.XXXXXX, so a search rooted at it matched the staging
  # directory before the archive root and the payload was never found.
  unpacked="${staging}/archive"
  mkdir -p "$unpacked"
  tar -xzf "$archive" -C "$unpacked"
  extracted="$(find "$unpacked" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi

if [[ -z "$extracted" || ! -d "$extracted/hack" || ! -d "$extracted/bootstrap" ]]; then
  echo "error: ${version} does not contain hack/ and bootstrap/" >&2
  exit 1
fi

# Everything the consumer's Makefile invokes has to be vendored, or the
# documented targets reference paths that were never installed.
payload="${staging}/payload"
mkdir -p "$payload"
cp -R "$extracted/hack" "$payload/hack"
cp -R "$extracted/bootstrap" "$payload/bootstrap"
if [[ -f "$extracted/VERSION" ]]; then
  cp "$extracted/VERSION" "$payload/VERSION"
fi

digest="$(infra_kit_tree_digest "$payload")"

# Remove then move, so a partial copy cannot be left looking like a valid
# vendor directory.
rm -rf -- "$vendor_abs"
mv "$payload" "$vendor_abs"
chmod -R u+rwX,go-w "$vendor_abs"
find "$vendor_abs" -name '*.sh' -exec chmod +x {} +

lock="${vendor_abs}.lock"
cat > "$lock" <<EOF
# Generated by sync.sh. Verified offline by verify.sh — do not edit by hand,
# and do not edit the vendored files: both make the digest fail.
version = ${version}
digest = sha256:${digest}
EOF
chmod 644 "$lock"

echo "vendored infra-kit ${version} into ${vendor_abs}"
echo "digest sha256:${digest}"
echo "lock ${lock}"
