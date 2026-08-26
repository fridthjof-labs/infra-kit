# Deterministic digest over a vendored directory.
#
# The lock file records what was vendored so that an offline check can prove
# the committed bytes are still upstream's. Without it, a local edit to a
# vendored script is invisible and becomes exactly the drift this repository
# exists to end.
# shellcheck shell=bash

infra_kit_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# sha256 over "<file digest>  <relative path>" lines, sorted by path, so the
# result depends on content and layout but not on filesystem order.
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
