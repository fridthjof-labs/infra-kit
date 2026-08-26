#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "sync download"

# The other tests all pass --source, so nothing ever exercised the branch a real
# consumer uses: download a tag archive and find the payload inside it.
work="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-download.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# Shaped like a GitHub tag archive: a single root directory holding the payload.
mkdir -p "$work/src/infra-kit-0.1.0"
cp -R "$KIT_ROOT/hack" "$KIT_ROOT/bootstrap" "$KIT_ROOT/VERSION" "$work/src/infra-kit-0.1.0/"
tar -czf "$work/release.tar.gz" -C "$work/src" infra-kit-0.1.0

# Stub both downloaders, so the result does not depend on whether this machine
# has gh installed or network access.
stub="$work/stub"
mkdir -p "$stub"
cat > "$stub/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${STUB_CURL_FAIL:-0}" == 1 ]]; then
  exit 22
fi
dest=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) dest="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$dest" ]] || exit 2
cp "$work/release.tar.gz" "\$dest"
EOF
cat > "$stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: stubbed out" >&2
exit 1
EOF
chmod +x "$stub/curl" "$stub/gh"

# A new consumer has only the downloaded sync.sh. Keeping digest.sh beside it
# here would hide a broken one-file bootstrap behind this checkout's layout.
standalone_sync="$work/sync.sh"
cp "$KIT_ROOT/bootstrap/sync.sh" "$standalone_sync"

vendor="$work/consumer/infra/hack/vendor/infra-kit"
out="$(PATH="$stub:$PATH" bash "$standalone_sync" \
  --version v0.1.0 --vendor-dir "$vendor" --repo example/infra-kit 2>&1)" ||
  fail "the download branch failed: $out"
pass "sync.sh vendors from a downloaded archive"

# The archive root and the staging directory both match infra-kit-*; unpacking
# into a child directory is what keeps the search off the staging directory.
[[ -d "$vendor/hack" && -d "$vendor/bootstrap" && -f "$vendor/VERSION" ]] ||
  fail "the payload was not extracted from the archive root: $out"
pass "the payload comes from the archive root, not the staging directory"

grep -q '^version = v0.1.0$' "${vendor}.lock" || fail "lock records the wrong version"
bash "$vendor/bootstrap/verify.sh" "$vendor" >/dev/null ||
  fail "the downloaded payload does not verify against its own lock"
pass "the downloaded payload verifies offline against the lock"

# No reachable download is a named failure, not a half-written vendor directory.
missing="$work/unreachable/infra-kit"
if out="$(PATH="$stub:$PATH" STUB_CURL_FAIL=1 bash "$standalone_sync" \
  --version v0.1.0 --vendor-dir "$missing" --repo example/infra-kit 2>&1)"; then
  fail "sync.sh reported success with no reachable download: $out"
fi
[[ "$out" == *"could not download"* ]] || fail "unhelpful download failure: $out"
[[ ! -e "$missing" ]] || fail "a failed download left a vendor directory behind"
pass "a failed download fails loudly and vendors nothing"
