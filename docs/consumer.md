# Adopting infra-kit

## 1. Vendor it

Nothing is installed yet, so fetch `sync.sh` once by hand:

<!-- x-release-please-start-version -->
```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.2.1/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh

bash /tmp/infra-kit-sync.sh \
  --version v0.2.1 \
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
gh api repos/YOUR-ORG/infra-kit/contents/bootstrap/sync.sh?ref=v0.2.1 \
  --jq .content | base64 -d > /tmp/infra-kit-sync.sh
```
<!-- x-release-please-end -->

The vendored payload contains everything the Makefile below invokes:

```
infra/
  .sops.yaml
  prod.secrets.auto.tfvars.enc
  hack/
    validate-secrets.sh          <- yours: the secret schema
    tofu-run.sh                  <- yours: how this repository runs Tofu
    vendor/
      infra-kit.lock             <- version + digest
      infra-kit/                 <- upstream, never edited
        VERSION
        hack/                    <- encrypt, edit, with-decrypt
        bootstrap/               <- sync, verify, digest
```

## 2. Point the Makefile at it

<!-- x-release-please-start-version -->
<!-- consumer-makefile:begin -->
```make
INFRA_KIT         := infra/hack/vendor/infra-kit
INFRA_KIT_VERSION := v0.2.1

export INFRA_KIT_ROOT          := $(CURDIR)/infra
export INFRA_KIT_TMP_PREFIX    := my-org
export INFRA_KIT_VALIDATE_HOOK := $(CURDIR)/infra/hack/validate-secrets.sh

.PHONY: validate encrypt edit sync-hack

# Offline: no network, no credentials. Verifying the vendored bytes belongs
# here, next to the other offline checks.
validate:
	bash $(INFRA_KIT)/bootstrap/verify.sh $(INFRA_KIT)
	tofu -chdir=infra validate

encrypt:
	$(INFRA_KIT)/hack/encrypt.sh

edit:
	$(INFRA_KIT)/hack/edit-encrypted.sh

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

## 3. Write the two adapters

Everything repository-specific stays yours.

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

`edit-encrypted.sh` runs it before re-encrypting; a non-zero exit aborts and
leaves the encrypted file untouched.

**Tofu execution** — roots, backends, state backup, and whether the repository
is single-root or multi-root are yours. `with-decrypt.sh` is the seam:

```bash
"$INFRA_KIT/hack/with-decrypt.sh" \
  TFVARS=infra/prod.secrets.auto.tfvars.enc \
  BACKEND=infra/backend.prod.hcl.enc \
  -- bash -lc 'tofu -chdir=infra init -reconfigure -backend-config="$BACKEND" \
                && tofu -chdir=infra plan -var-file="$TFVARS"'
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
