<p align="center">
  <img src="assets/infra-kit-icon.png" alt="Infra Kit icon" width="180">
</p>

# infra-kit

[![Quality](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/fridthjof-labs/infra-kit)](https://github.com/fridthjof-labs/infra-kit/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Small, auditable shell tools for using SOPS-encrypted secrets with OpenTofu.
Infra-kit is vendored into each infrastructure repository, pinned by version and
digest, and runs offline after installation.

It does three things:

- `encrypt.sh` encrypts a plaintext file and removes the plaintext.
- `edit-encrypted.sh` opens a mode-0600 temporary file, validates it, encrypts
  it back, and removes the temporary file.
- `with-decrypt.sh` streams plaintext to a command through a FIFO, so plan and
  apply do not need a plaintext secrets file.

## Install

Prerequisites: Bash, [SOPS](https://github.com/getsops/sops), and
[age](https://github.com/FiloSottile/age). Use this bootstrap guide:

- [docs/encryption-bootstrap.md](/docs/encryption-bootstrap.md)

If your key file is not the default above, set:

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/fido2.txt"
```

<!-- x-release-please-start-version -->
```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.2.2/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh

bash /tmp/infra-kit-sync.sh \
  --version v0.2.2 \
  --vendor-dir infra/hack/vendor/infra-kit
```
<!-- x-release-please-end -->

Commit both generated paths:

```text
infra/hack/vendor/infra-kit/
infra/hack/vendor/infra-kit.lock
```

The lock records the version and exact payload digest. Later upgrades use the
vendored `sync.sh`; validation and infrastructure operations never download
code.

## Use

The consumer Makefile supplies the infrastructure root and exposes short local
commands:

```make
INFRA_KIT := infra/hack/vendor/infra-kit
export INFRA_KIT_ROOT := $(CURDIR)/infra

encrypt:
	$(INFRA_KIT)/hack/encrypt.sh

edit:
	$(INFRA_KIT)/hack/edit-encrypted.sh

validate:
	bash $(INFRA_KIT)/bootstrap/verify.sh $(INFRA_KIT)
```

Then the normal workflow is:

```bash
make encrypt   # first encryption
make edit      # later changes
make validate  # verify the vendored payload
```

See the [consumer guide](docs/consumer.md) for the complete Makefile, optional
plaintext validation hook, upgrades, and FIFO-based OpenTofu execution.

## Security model

- Encryption recipients come only from the consumer's `.sops.yaml`.
- Explicit `SOPS_AGE_KEY` or `SOPS_AGE_KEY_FILE` values override the standard
  local age identity.
- Editing uses a private temporary directory and removes plaintext on success,
  failure, and handled signals.
- Command execution uses FIFOs and never writes decrypted input to a regular
  file.
- Encryption writes to a temporary output first, so failure cannot truncate a
  valid encrypted file.
- Vendored files are reviewable and verified offline against their committed
  digest.

Repository-specific secret schemas, OpenTofu roots, state handling, and backup
policy remain in the consumer repository.

## Development

```bash
make check
```

This runs syntax checks, ShellCheck, real SOPS/age round trips, consumer
adoption, FIFO cleanup, failure atomicity, release configuration, and the public
download path.

Security policy: [SECURITY.md](SECURITY.md). Licensed under the [MIT
License](LICENSE).
