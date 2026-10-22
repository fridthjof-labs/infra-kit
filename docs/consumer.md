# Adopting infra-kit

Start with the [encryption quickstart](../README.md#get-started) and
[key setup](encryption-bootstrap.md). Your repository supplies `.sops.yaml`,
plaintext ignore rules, and any validation hook. Infra-kit does not manage
backends, state, deployments, or CI workflows.

The shared Make include is unreleased. Until the next release, use the reviewed
source checkout with `bootstrap/sync.sh --source PATH --version COMMIT` for
evaluation; the v0.5 installer below does not contain the new interface.

## 1. Vendor it

Nothing is installed yet, so fetch `sync.sh` once by hand:

<!-- x-release-please-start-version -->
```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.5.0/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh

bash /tmp/infra-kit-sync.sh \
  --version v0.5.0 \
  --vendor-dir infra/vendor/infra-kit
```

This one file is the only thing you take on trust: it arrives before there is a
lock to check it against, so read it before you run it. Everything it then
vendors is digest-checked from that point on.

That writes `infra/vendor/infra-kit/` and
`infra/vendor/infra-kit.lock`. **Commit both.** The vendored files are
reviewed upstream payload; the lock records its expected contents. Upgrade with `make sync-infra-kit`
— this manual step happens once.

If you are adopting a private fork instead, `sync.sh` falls back to an
authenticated `gh`, and the manual fetch above becomes:

```bash
gh api repos/YOUR-ORG/infra-kit/contents/bootstrap/sync.sh?ref=v0.5.0 \
  --jq .content | base64 -d > /tmp/infra-kit-sync.sh
```
<!-- x-release-please-end -->

## 2. Add Makefile targets

Include the shared targets instead of copying recipes. Set `FILE` to the plaintext filename relative to the repository root.
The edit target uses its encrypted `.enc` counterpart.

<!-- x-release-please-start-version -->
<!-- consumer-makefile:begin -->
```make
INFRA_KIT         := infra/vendor/infra-kit
INFRA_KIT_VERSION := v0.5.0
export INFRA_KIT_ROOT := $(CURDIR)/infra
FILE ?= infra/secrets.env
# Optional shared operations file; omit when your project has none.
INFRA_KIT_OPS_PLAINTEXT := infra/ops.env

include $(INFRA_KIT)/make/secrets.mk
```
<!-- consumer-makefile:end -->
<!-- x-release-please-end -->

Commit the encrypted files, public recipients, vendored files, and lock.
Keep private identities outside the repository and ignore plaintext filenames.
`verify-infra-kit` checks only the vendored payload; it does not scan your repository
for secrets or validate infrastructure.

Use `make encrypt`, `make edit`, `make encrypt-ops`, and `make edit-ops`.
For per-root secrets, set `FILE ?= infra/$(ROOT)/secrets.auto.tfvars` in your
Makefile. Existing project targets such as `plan` and `apply` remain local.
The shared encryption targets verify the payload before using it.

## 3. Use 1Password at runtime

Install and authenticate the 1Password CLI using its normal desktop integration
or a scoped service account. Put secret references, not secret values, in a
project file such as `.env.op`:

```dotenv
API_TOKEN=op://YOUR-VAULT/YOUR-ITEM/credential
```

```sh
make op-run OP_ENV_FILE=.env.op COMMAND='./scripts/deploy.sh'
```

`OP_ENV_FILE` is optional when references are already exported in the environment.
The target delegates to `op run` and keeps its default output masking. It does
not need SOPS or an age identity. `COMMAND` is a shell command; use a script
when quoting gets complicated. Failures propagate to Make. Do not put actual
secrets in `COMMAND` or Make variables.

No vault items are created, copied into SOPS, or written to plaintext files.
Only commit reference files when their vault and item names are suitable for
that repository's audience; otherwise ignore the file. Runtime environment
variables and output masking are not protection against the invoked program
or other processes running as the same user.

## 4. Consume encrypted input

```bash
bash infra/vendor/infra-kit/scripts/with-decrypt.sh \
  CONFIG=infra/secrets.env.enc -- bash -c 'some-tool --config "$CONFIG"'
```

Each variable points to a private FIFO. The command must read each FIFO exactly
once: an unread FIFO fails the run, and reading twice blocks. Infra-kit does
not write decrypted input to a regular file, but the receiving command can.

Set `SOPS_AGE_KEY_FILE` to your private identity, or supply `SOPS_AGE_KEY`
inline in an environment that needs it. Explicit keys override the platform
defaults described in [key setup](encryption-bootstrap.md).

## Validation hooks

Set `INFRA_KIT_VALIDATE_HOOK` to an executable that accepts the plaintext
filename and exits nonzero when invalid. Encrypt and edit run it before
replacing ciphertext; rejection preserves the input and existing encrypted file.
An unchanged edit does not re-encrypt or run the hook.

For a separate operations-file validator, set `INFRA_KIT_OPS_VALIDATE_HOOK`.
It applies only to `encrypt-ops` and `edit-ops`.

For compatibility, files named `ops.env` still receive Bash syntax validation
and bypass the custom hook. This does not validate an infrastructure schema.
Use another filename when your custom hook must validate an environment file.

## Upgrading

<!-- x-release-please-start-version -->
```bash
make sync-infra-kit INFRA_KIT_VERSION=v0.5.0
git diff infra/vendor      # review what changed
make verify-infra-kit
```
<!-- x-release-please-end -->

The diff is the review. Nothing upgrades during a deploy.

## If verification fails

```
error: vendored infra-kit does not match infra/vendor/infra-kit.lock
  expected sha256:…
  actual   sha256:…
a vendored file was edited locally; re-run make sync-infra-kit or revert it
```

The vendored files differ from the committed lock. Review the changes before
reverting or re-syncing. Keep repository-specific changes in your adapters so
they are not overwritten by the next upgrade.

`verify.sh` is itself vendored, so it guards against accident rather than
against someone with commit access. The lock is committed: a change to either
shows up in `git diff`, which is the real control.
