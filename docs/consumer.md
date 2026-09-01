# Adopting infra-kit

A brand-new repository should not follow this page by hand: vendor the kit
(step 1), then let `bootstrap/scaffold.sh` write the canonical layout —
Makefile, workflow, sops rules, first root — in one command. This page is the
contract behind that layout, and the path for an existing repository adopting
it incrementally. The full execution model lives in
[tofu-standard.md](tofu-standard.md).

## 1. Vendor it

Nothing is installed yet, so fetch `sync.sh` once by hand:

<!-- x-release-please-start-version -->
```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.3.1/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh

bash /tmp/infra-kit-sync.sh \
  --version v0.3.1 \
  --vendor-dir infra/hack/vendor/infra-kit
```

This one file is the only thing you take on trust: it arrives before there is a
lock to check it against, so read it before you run it. Everything it then
vendors is digest-checked from that point on.

That writes `infra/hack/vendor/infra-kit/` and
`infra/hack/vendor/infra-kit.lock`. **Commit both.** The vendored files are
upstream's; the lock is what proves it. Every later upgrade is `make sync-hack`
— this manual step happens once.

If you are adopting a private fork instead, `sync.sh` falls back to an
authenticated `gh`, and the manual fetch above becomes:

```bash
gh api repos/YOUR-ORG/infra-kit/contents/bootstrap/sync.sh?ref=v0.3.1 \
  --jq .content | base64 -d > /tmp/infra-kit-sync.sh
```
<!-- x-release-please-end -->

`INFRA_KIT_VALIDATE_HOOK` describes the roots' `secrets.auto.tfvars` files.
Exporting it for every target is fine: `ops.env` is the kit's own file and
never reaches the hook. Encryption only checks that it parses; the
state-access schema is checked at run time against the merged base and overlay.

The vendored payload contains everything the Makefile below invokes:

```
infra/
  .sops.yaml
  ops.env.enc                    <- shared operations file (state + credentials)
  site/                          <- one directory per OpenTofu root
    *.tf
    secrets.auto.tfvars.enc      <- optional root-scoped secrets
  hack/
    validate-secrets.sh          <- yours: the secret schema
    vendor/
      infra-kit.lock             <- version + digest
      infra-kit/                 <- upstream, never edited
        VERSION
        hack/                    <- encrypt, edit, with-decrypt, tofu-run,
                                    tofu-validate, scan-repo
        bootstrap/               <- sync, verify, digest, scaffold
```

## 2. Point the Makefile at it

<!-- x-release-please-start-version -->
<!-- consumer-makefile:begin -->
```make
INFRA_KIT         := infra/hack/vendor/infra-kit
INFRA_KIT_VERSION := v0.3.1

export INFRA_KIT_ROOT          := $(CURDIR)/infra
export INFRA_KIT_STATE_PREFIX  := my-org
export INFRA_KIT_TMP_PREFIX    := my-org
export INFRA_KIT_VALIDATE_HOOK := $(CURDIR)/infra/hack/validate-secrets.sh

# State operations are per-root: make plan ROOT=site.
ROOT ?= site

.PHONY: validate plan apply backup encrypt edit edit-ops sync-hack

# Offline: no network, no credentials. Verifying the vendored bytes belongs
# here, next to the other offline checks.
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
	bash $(INFRA_KIT)/hack/encrypt.sh infra/$(ROOT)/secrets.auto.tfvars

edit:
	bash $(INFRA_KIT)/hack/edit-encrypted.sh infra/$(ROOT)/secrets.auto.tfvars.enc

edit-ops:
	bash $(INFRA_KIT)/hack/edit-encrypted.sh infra/ops.env.enc

# The only target that reaches the network. sync.sh replaces the directory it
# is running from, so it re-execs itself from a copy first.
sync-hack:
	bash $(INFRA_KIT)/bootstrap/sync.sh \
	  --version $(INFRA_KIT_VERSION) --vendor-dir $(INFRA_KIT)
```
<!-- consumer-makefile:end -->
<!-- x-release-please-end -->

`tests/consumer_test.sh` extracts that block from this file and runs it, so the
documentation and the tested behaviour cannot drift apart.

Local decryption uses an explicit `SOPS_AGE_KEY` or `SOPS_AGE_KEY_FILE` when
set. Otherwise it uses the platform default:
`~/.config/sops/age/secure-enclave.txt` on macOS, `~/.config/sops/age/fido2.txt` on Linux.

## 3. Write the adapters

Everything repository-specific stays yours; since v0.3 that no longer includes
the Tofu driver itself.

**`validate-secrets.sh`** — takes a plaintext file, exits non-zero if a
required key is missing. This is the file that differed most between
repositories, because the required keys genuinely differ:

```bash
#!/usr/bin/env bash
set -euo pipefail
plaintext="$1"
missing=()
for key in SESSION_SECRET GOOGLE_CLIENT_ID; do
  grep -q "^\s*${key}\s*=" "$plaintext" || missing+=("$key")
done
if ((${#missing[@]})); then
  printf 'missing required secret: %s\n' "${missing[@]}" >&2
  echo "fix it with: make edit" >&2
  exit 1
fi
```

Both `encrypt.sh` and `edit-encrypted.sh` run it before writing; a non-zero
exit aborts and leaves the input and any existing `.enc` untouched. A
first encryption is where a missing required key is cheapest to catch, so the
hook is not an edit-only guard.

`edit-encrypted.sh` compares the plaintext before and after your editor. A save
that changed nothing prints `unchanged:` and does not re-encrypt — sops mints a
fresh data key every time, so an unconditional rewrite would change the
ciphertext and leave a dropped paste looking exactly like a real edit, in the
command output and in `git diff` alike. Nothing being written also means there
is nothing for the hook to validate, so it does not run on that path.

**`INFRA_KIT_OPS_HOOK`** (optional) — an executable run inside every
`tofu-run.sh` invocation after the operations file is sourced, with
`INFRA_KIT_TOFU_ROOT` naming the root. The kit already requires the state
contract (`INFRA_KIT_STATE_BUCKET`, `INFRA_KIT_STATE_ENDPOINT`, the two AWS
keys); the hook asserts whatever else your providers need, and can treat an
exceptional root differently instead of forking the driver.

**Tofu execution is the kit's.** `tofu-run.sh` decrypts through one-use FIFOs,
derives the state key, initializes the locked backend, snapshots state before
apply, and streams root secrets as `-var-file`. `with-decrypt.sh` remains the
seam for anything else that needs a secret in flight:

```bash
"$INFRA_KIT/hack/with-decrypt.sh" \
  TFVARS=infra/site/secrets.auto.tfvars.enc \
  -- bash -c 'some-tool --config "$TFVARS"'
```

Each name becomes a FIFO. Plaintext is streamed and never written to a file. If
the command never reads a secret, `with-decrypt.sh` exits non-zero — a command
that silently ignored its input is a misconfiguration, not a success.

## Upgrading

```bash
make sync-hack INFRA_KIT_VERSION=v0.2.0
git diff infra/hack/vendor      # review what changed
make validate
```

The diff is the review. Nothing upgrades during a deploy.

## If verification fails

```
error: vendored infra-kit does not match infra/hack/vendor/infra-kit.lock
  expected sha256:…
  actual   sha256:…
a vendored file was edited locally; re-run make sync-hack or revert it
```

Someone changed an upstream file in place. Either the change belongs upstream —
send it there and sync a new version — or it belongs in your adapters. It does
not belong in the vendor directory, which is how the three copies diverged in
the first place.

`verify.sh` is itself vendored, so it guards against accident rather than
against someone with commit access. The lock is committed: a change to either
shows up in `git diff`, which is the real control.
