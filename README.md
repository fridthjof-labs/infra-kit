<p align="center">
  <img src="assets/infra-kit-icon.png" alt="Infra Kit icon" width="180">
</p>

# infra-kit

[![Quality](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/fridthjof-labs/infra-kit)](https://github.com/fridthjof-labs/infra-kit/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Shared secrets commands for my infrastructure repositories. SOPS and age handle
encrypted files in Git; 1Password supplies runtime secrets through `op run`.
Infra-kit adds a Make interface and a pinned, vendored copy of the helpers.

- `make encrypt` and `make edit` work on SOPS-encrypted files.
- `make encrypt-ops` and `make edit-ops` use a separate operations file and hook.
- `make op-run COMMAND='./scripts/deploy.sh'` supplies secrets from 1Password.
- `scripts/with-decrypt.sh` gives a command one-use FIFOs for encrypted files.

## Why this exists

I use the same commands and validation hooks across my repositories. This keeps
those recipes in one place. It is a small collection of personal conventions,
not a secrets manager or a requirement for using SOPS or 1Password.

The encryption helpers preserve validation hooks, atomic writes and temporary-file
cleanup. There is no deployment orchestration or background service.

## Layout

- `make/secrets.mk`: shared SOPS, 1Password and vendor targets.
- `scripts/`: encryption and command helpers; `scripts/lib/` is internal support.
- `bootstrap/`: installation and offline payload verification.
- `tests/` and `docs/`: executable examples, behavior checks and usage notes.

## Get started

The shared Make interface and `scripts/` layout are unreleased. When upgrading
from v0.5, follow the [layout migration](docs/migration.md#shared-make-interface).
The release-pinned installer below still installs v0.5 until the next release.
To try this branch, vendor the reviewed checkout before using the examples:

```bash
bash /path/to/infra-kit/bootstrap/sync.sh \
  --source /path/to/infra-kit \
  --version "$(git -C /path/to/infra-kit rev-parse HEAD)" \
  --vendor-dir infra/vendor/infra-kit
```

Install Bash, Git, curl, [SOPS](https://github.com/getsops/sops), and
[age](https://github.com/FiloSottile/age). Download and inspect the installer,
then vendor a release into your repository:

<!-- x-release-please-start-version -->
```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/v0.5.0/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh

less /tmp/infra-kit-sync.sh
bash /tmp/infra-kit-sync.sh \
  --version v0.5.0 \
  --vendor-dir infra/vendor/infra-kit
```
<!-- x-release-please-end -->

Commit both `infra/vendor/infra-kit/` and `infra/vendor/infra-kit.lock`.
The lock records the version and payload digest. Check the vendored files with:

```bash
bash infra/vendor/infra-kit/bootstrap/verify.sh infra/vendor/infra-kit
```

Follow [key setup](docs/encryption-bootstrap.md) to create and test an identity.
Create `infra/.sops.yaml` with its **public recipient**, replacing the placeholder:

```yaml
creation_rules:
  - path_regex: \.(env|tfvars|hcl)$
    age: REPLACE_WITH_YOUR_PUBLIC_RECIPIENT
```

Keep private identities outside the repository. Add plaintext secret filenames
to `.gitignore` before using real data. With `SOPS_AGE_KEY_FILE` set to your
identity, try a harmless value:

<!-- encryption-quickstart:begin -->
```bash
export INFRA_KIT_ROOT="$PWD/infra"
kit=infra/vendor/infra-kit
umask 077
printf 'example = "hello"\n' > infra/example.tfvars
bash "$kit/scripts/encrypt.sh" infra/example.tfvars
bash "$kit/scripts/with-decrypt.sh" CONFIG=infra/example.tfvars.enc \
  -- bash -c 'cat "$CONFIG"'
```
<!-- encryption-quickstart:end -->

The example prints the harmless value to your terminal. For real secrets, pass
the FIFO to the program that needs them. Each FIFO must be read once: a second
read blocks, and leaving one unread makes the command fail. A receiving program
can still log or persist its input.

To use the shared `make edit` and `make encrypt` commands, include
[`make/secrets.mk`](docs/consumer.md#2-add-makefile-targets). To call the script directly:

```bash
bash "$kit/scripts/edit-encrypted.sh" infra/example.tfvars.enc
```

## Upgrading

Version 0.5 removed OpenTofu orchestration, repository scanning, project
generators, and reusable CI workflows. Existing pins still work. Read the
[migration notes](docs/migration.md) before upgrading a consumer that uses them.
For Makefile integration and verified updates, see the [consumer guide](docs/consumer.md).

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

Your repository supplies `.sops.yaml` recipients and any secret validation hooks.

## Development

```bash
make check
```

This runs syntax checks, ShellCheck, real SOPS/age round trips, consumer
adoption, FIFO cleanup, failure atomicity, release configuration, and the public
download path.

Security policy: [SECURITY.md](SECURITY.md). Licensed under the [MIT
License](LICENSE).
