<p align="center">
  <img src="assets/infra-kit-icon.png" alt="Infra Kit icon" width="180">
</p>

# infra-kit

[![Quality](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/fridthjof-labs/infra-kit)](https://github.com/fridthjof-labs/infra-kit/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Small, auditable shell tools for using SOPS-encrypted secrets with OpenTofu.
Infra-kit is vendored into each infrastructure repository, pinned by version and
digest. Verifying the vendored payload is offline; OpenTofu initialization
may download providers and modules, and plan/apply contact remote services.

It owns two layers:

Encryption —

- `encrypt.sh` encrypts a plaintext file and removes the plaintext.
- `edit-encrypted.sh` opens a mode-0600 temporary file, validates it, encrypts
  it back, and removes the temporary file.
- `with-decrypt.sh` streams plaintext to a command through a FIFO, so plan and
  apply do not need a plaintext secrets file.

Execution ([the OpenTofu standard](/docs/tofu-standard.md)) —

- `tofu-run.sh` is the one path to production state: it sources the encrypted
  operations file through a FIFO, derives each root's state key, initializes
  the locked backend, snapshots state before apply, and streams root secrets
  as a one-use `-var-file`.
- `tofu-validate.sh` and `scan-repo.sh` validate without production credentials: per-root fmt,
  lock-file init, and validate, plus a scan for plaintext secrets, keys, and
  state in the checkout.
- `bootstrap/scaffold.sh` writes the whole canonical consumer layout —
  Makefile, sops rules, first root, gated CI workflow — into an empty
  repository, so every new IaC repository starts identical.

## Start a new infrastructure repository

Install Git, Bash, curl, and [mise](https://mise.jdx.dev/getting-started.html).
Start in an empty Git repository. Download and inspect the bootstrap script,
then vendor the release:

<!-- x-release-please-start-version -->
```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.3.2/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh

less /tmp/infra-kit-sync.sh
bash /tmp/infra-kit-sync.sh \
  --version v0.3.2 \
  --vendor-dir infra/hack/vendor/infra-kit
```
<!-- x-release-please-end -->

Scaffold the Makefile, tool pins, encryption rules, first OpenTofu root, and CI
workflow. Replace `my-org` and `platform` with your state prefix and root name:

<!-- quickstart-scaffold:begin -->
```bash
bash infra/hack/vendor/infra-kit/bootstrap/scaffold.sh \
  --state-prefix my-org --root platform --tofu-dir infra
```
<!-- quickstart-scaffold:end -->

Run `mise install` to install the generated tool pins.
Follow [encryption key setup](docs/encryption-bootstrap.md) to create and test
the operator, dedicated CI, and recovery identities. Put their **public
recipients** in `infra/.sops.yaml`. Create the state bucket and scoped credentials
as described in the [operations-file contract](docs/tofu-standard.md), fill in
`infra/ops.env` from `infra/ops.env.example`, then run:

```bash
mise exec -- make encrypt-ops
mise exec -- make validate
mise exec -- make plan ROOT=platform
```

Set the repository's `Production` environment secret `SOPS_AGE_KEY` to its
dedicated CI identity. Configure that environment's protection rules before
using the generated plan/apply workflow. For the first apply only, when no state
exists yet, use `SKIP_STATE_BACKUP=1 mise exec -- make apply ROOT=platform`.
Later applies take a state backup first.

Commit the generated layout, encrypted operations file, and both vendored paths:

```text
infra/hack/vendor/infra-kit/
infra/hack/vendor/infra-kit.lock
```

The lock records the version and exact payload digest. `verify.sh` checks it
offline. `make validate` needs no production credentials or backend access,
but OpenTofu initialization may download providers and modules. Plan and apply
contact your backend and providers; they never upgrade infra-kit.

## Adopt into an existing repository

Use the [consumer guide](docs/consumer.md) for incremental adoption, Makefile
integration, validation hooks, and upgrades. The scaffold refuses to overwrite
existing files.

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

Repository-specific secret schemas, the OpenTofu roots themselves, provider
choices, and the `.sops.yaml` recipient set remain in the consumer repository;
how Tofu runs against state is the kit's ([docs/tofu-standard.md](/docs/tofu-standard.md)).

## Development

```bash
make check
```

This runs syntax checks, ShellCheck, real SOPS/age round trips, consumer
adoption, FIFO cleanup, failure atomicity, release configuration, and the public
download path.

Security policy: [SECURITY.md](SECURITY.md). Licensed under the [MIT
License](LICENSE).
