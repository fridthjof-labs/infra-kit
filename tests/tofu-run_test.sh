#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT

echo "tofu-run driver"

make_consumer

# The tofu layer also encrypts ops.env files; widen the test recipient rules
# the way the scaffold writes them.
cat > "$consumer/infra/.sops.yaml" <<EOF
creation_rules:
  - path_regex: \.(tfvars|hcl|env)\$
    age: $(grep -o 'age1[0-9a-z]*' "$consumer/identity.txt" | head -1)
EOF

export INFRA_KIT_TOFU_DIR="$consumer/infra"
export INFRA_KIT_STATE_PREFIX="testorg"

# A stub tofu records every invocation and behaves just enough like the real
# one: it consumes any -var-file (a FIFO carries content exactly once and
# with-decrypt fails when a secret goes unread) and answers state pull.
mkdir -p "$consumer/stub" "$consumer/infra/site"
export TOFU_LOG="$consumer/tofu.log"
cat > "$consumer/stub/tofu" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$TOFU_LOG"
for a in "$@"; do
  case "$a" in
    -var-file=*) cat "${a#-var-file=}" >/dev/null ;;
  esac
done
if [[ "${2:-}" == state && "${3:-}" == pull ]]; then
  printf '{"version":4,"serial":1}\n'
fi
exit 0
EOF
chmod +x "$consumer/stub/tofu"
export PATH="$consumer/stub:$PATH"

echo 'resource "null_resource" "x" {}' > "$consumer/infra/site/main.tf"

secret="$(secret_token)"
cat > "$consumer/infra/ops.env" <<EOF
INFRA_KIT_STATE_BUCKET=test-bucket
INFRA_KIT_STATE_ENDPOINT=https://example.r2.cloudflarestorage.com
AWS_ACCESS_KEY_ID=stub-key-id
AWS_SECRET_ACCESS_KEY=${secret}
OPS_MARKER=shared
EOF
"$hack/encrypt.sh" "$consumer/infra/ops.env" >/dev/null
[[ -f "$consumer/infra/ops.env.enc" ]] || fail "ops.env was not encrypted"

run="$hack/tofu-run.sh"

# plan: derived state key, rendered backend config, no snapshot
: >"$TOFU_LOG"
out="$("$run" site plan 2>&1)" || fail "plan failed: $out"
[[ "$out" == *"testorg/site/production.tfstate"* ]] ||
  fail "plan did not derive the conventional state key: $out"
grep -q -- '-backend-config=' "$TOFU_LOG" || fail "init never received a backend config"
grep -q '^-chdir=.* plan -input=false' "$TOFU_LOG" || fail "plan was never invoked: $(cat "$TOFU_LOG")"
backend_file="$consumer/infra/site/.terraform/backend.hcl"
grep -q 'bucket = "test-bucket"' "$backend_file" || fail "backend config missing bucket"
grep -q 'key    = "testorg/site/production.tfstate"' "$backend_file" || fail "backend config missing key"
[[ ! -d "$consumer/state-backups" ]] || fail "plan must not snapshot state"
pass "plan renders the backend for the derived state key"

# the plaintext never lands anywhere in the consumer during a run
found="$(plaintext_files_containing "$consumer" "$secret" | grep -v '/ops.env$' || true)"
[[ -z "$found" ]] || fail "plaintext ops material written to disk: $found"
rm -f "$consumer/infra/ops.env"
pass "ops plaintext is streamed, never written"

# apply: snapshot first, then auto-approve only when CI says so
: >"$TOFU_LOG"
out="$(TOFU_AUTO_APPROVE=1 "$run" site apply 2>&1)" || fail "apply failed: $out"
snapshot="$(find "$consumer/state-backups" -name 'site-*.tfstate' | head -1)"
[[ -n "$snapshot" && -s "$snapshot" ]] || fail "apply took no state snapshot"
[[ -f "$snapshot.sha256" ]] || fail "snapshot has no checksum"
grep -q ' apply -input=false -auto-approve' "$TOFU_LOG" || fail "apply flags wrong: $(cat "$TOFU_LOG")"
pass "apply snapshots state first"

count_before="$(find "$consumer/state-backups" -name '*.tfstate' | wc -l)"
out="$(TOFU_AUTO_APPROVE=1 SKIP_STATE_BACKUP=1 "$run" site apply 2>&1)" || fail "apply failed: $out"
count_after="$(find "$consumer/state-backups" -name '*.tfstate' | wc -l)"
[[ "$count_before" == "$count_after" ]] || fail "SKIP_STATE_BACKUP still snapshotted"
pass "SKIP_STATE_BACKUP covers the first-ever apply"

# backup: snapshot and stop
: >"$TOFU_LOG"
out="$("$run" site backup 2>&1)" || fail "backup failed: $out"
grep -q ' state pull' "$TOFU_LOG" || fail "backup never pulled state"
if grep -qE ' (plan|apply) ' "$TOFU_LOG"; then
  fail "backup must not plan or apply"
fi
pass "backup pulls a snapshot and stops"

# per-root secrets are streamed as a -var-file
tfvars_secret="$(secret_token)"
printf 'token = "%s"\n' "$tfvars_secret" > "$consumer/infra/site/secrets.auto.tfvars"
"$hack/encrypt.sh" "$consumer/infra/site/secrets.auto.tfvars" >/dev/null
: >"$TOFU_LOG"
out="$("$run" site plan 2>&1)" || fail "plan with secrets failed: $out"
grep -q -- '-var-file=' "$TOFU_LOG" || fail "secrets were never passed to tofu"
pass "root secrets ride along as a one-use var-file"

# a plaintext twin would be auto-loaded by tofu and silently win
printf 'token = "stale"\n' > "$consumer/infra/site/secrets.auto.tfvars"
if out="$("$run" site plan 2>&1)"; then
  fail "plan accepted a plaintext secrets.auto.tfvars: $out"
fi
rm -f "$consumer/infra/site/secrets.auto.tfvars"
pass "plaintext secrets refuse the run"

# state-key pins a pre-convention key for adopted roots
echo 'legacy/global.tfstate' > "$consumer/infra/site/state-key"
out="$("$run" site plan 2>&1)" || fail "plan with state-key failed: $out"
[[ "$out" == *"legacy/global.tfstate"* ]] || fail "state-key override ignored: $out"
rm -f "$consumer/infra/site/state-key"
pass "state-key overrides the derived key"

# the root overlay is sourced after the shared file; the consumer hook sees
# the merged env and knows which root it is validating
cat > "$consumer/infra/site/ops.env" <<'EOF'
OPS_MARKER=overlay
EOF
"$hack/encrypt.sh" "$consumer/infra/site/ops.env" >/dev/null
cat > "$consumer/hook.sh" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$INFRA_KIT_TOFU_ROOT" "\$OPS_MARKER" > "$consumer/hook.out"
EOF
chmod +x "$consumer/hook.sh"
out="$(INFRA_KIT_OPS_HOOK="$consumer/hook.sh" "$run" site plan 2>&1)" ||
  fail "plan with overlay failed: $out"
[[ "$(cat "$consumer/hook.out")" == "site overlay" ]] ||
  fail "overlay or hook contract broken: $(cat "$consumer/hook.out")"
rm -f "$consumer/infra/site/ops.env.enc"
pass "root overlay merges over the shared ops file, hook sees the root"

# a failing hook stops the run before any tofu invocation
cat > "$consumer/hook.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
: >"$TOFU_LOG"
if out="$(INFRA_KIT_OPS_HOOK="$consumer/hook.sh" "$run" site plan 2>&1)"; then
  fail "a failing ops hook did not stop the run"
fi
[[ ! -s "$TOFU_LOG" ]] || fail "tofu ran despite a failing ops hook"
pass "a failing ops hook stops the run before tofu"

# an incomplete operations file is caught before anything runs
cat > "$consumer/infra/ops.env" <<'EOF'
INFRA_KIT_STATE_BUCKET=replace-with-state-bucket
INFRA_KIT_STATE_ENDPOINT=https://example.r2.cloudflarestorage.com
AWS_ACCESS_KEY_ID=stub-key-id
AWS_SECRET_ACCESS_KEY=stub-secret
EOF
"$hack/encrypt.sh" "$consumer/infra/ops.env" >/dev/null
if out="$("$run" site plan 2>&1)"; then
  fail "a placeholder ops value was accepted: $out"
fi
[[ "$out" == *"INFRA_KIT_STATE_BUCKET"* ]] || fail "wrong ops failure: $out"
pass "placeholder ops values count as missing"

# unknown roots and bad names fail fast
if "$run" nope plan >/dev/null 2>&1; then
  fail "a directory with no .tf files passed as a root"
fi
if "$run" '../escape' plan >/dev/null 2>&1; then
  fail "a path-traversal root name was accepted"
fi
pass "root names are validated"
