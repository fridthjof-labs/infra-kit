# Adopting infra-kit

## 1. Vendor it

```bash
mkdir -p infra/hack/vendor
curl -fsSL https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.1.0/bootstrap/sync.sh -o /tmp/sync.sh
bash /tmp/sync.sh --version v0.1.0 --vendor-dir infra/hack/vendor/infra-kit
```

That writes `infra/hack/vendor/infra-kit/` and `infra/hack/vendor/infra-kit.lock`.
**Commit both.** The vendored files are upstream's; the lock is what proves it.

Keep the vendor directory separate from your own scripts, so the boundary is
visible in the tree:

```
infra/
  .sops.yaml
  prod.secrets.auto.tfvars.enc
  hack/
    validate-secrets.sh      <- yours: the secret schema
    tofu-run.sh              <- yours: how this repository runs Tofu
    vendor/
      infra-kit.lock         <- version + digest
      infra-kit/             <- upstream, never edited
```

## 2. Point the Makefile at it

```make
INFRA_KIT := infra/hack/vendor/infra-kit

export INFRA_KIT_ROOT          := $(CURDIR)/infra
export INFRA_KIT_TMP_PREFIX    := my-org
export INFRA_KIT_VALIDATE_HOOK := $(CURDIR)/infra/hack/validate-secrets.sh

.PHONY: validate encrypt edit sync-hack

# Offline: no network, no credentials. Verifying the vendored bytes belongs
# here, next to the other offline checks.
validate:
	bash bootstrap/verify.sh $(INFRA_KIT)
	./infra/hack/validate-secrets.sh --schema-only
	tofu -chdir=infra validate

encrypt:
	$(INFRA_KIT)/encrypt.sh

edit:
	$(INFRA_KIT)/edit-encrypted.sh

# The only target that reaches the network.
sync-hack:
	bash $(INFRA_KIT)/../../../bootstrap/sync.sh \
	  --version $(INFRA_KIT_VERSION) --vendor-dir $(INFRA_KIT)
```

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
"$INFRA_KIT/with-decrypt.sh" \
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
