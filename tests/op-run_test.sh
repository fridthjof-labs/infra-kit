#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap cleanup_consumer EXIT
make_consumer
cat > "$consumer/Makefile" <<EOF
INFRA_KIT := $vendor
include \$(INFRA_KIT)/make/secrets.mk
EOF
mkdir "$consumer/stub"
cat > "$consumer/stub/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == run ]] || exit 41
shift
if [[ -n "${OP_ENV_FILE:-}" ]]; then
  [[ "$1" == "--env-file=$OP_ENV_FILE" ]] || exit 42
  shift
fi
[[ "$1" == -- ]] || exit 43
shift
[[ "$1" == sh && "$2" == -c ]] || exit 44
export INJECTED=sample
exec "$@"
EOF
chmod +x "$consumer/stub/op"
export PATH="$consumer/stub:$PATH"
# Referenced values are resolved by op before the child shell expands them.
# shellcheck disable=SC2016
(cd "$consumer" && make op-run COMMAND='test "$$INJECTED" = sample' >/dev/null)
# shellcheck disable=SC2016
(cd "$consumer" && make op-run OP_ENV_FILE='references with spaces.env' COMMAND='test "$$INJECTED" = sample' >/dev/null)
if # shellcheck disable=SC2016
(cd "$consumer" && make op-run COMMAND=false >/dev/null 2>&1); then fail 'child failure lost'; fi
if (cd "$consumer" && make op-run >/dev/null 2>&1); then fail 'missing command accepted'; fi
pass 'op-run forwards reference file and command, keeps masking, and propagates failure'
