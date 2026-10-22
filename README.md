<p align="center">
  <img src="assets/infra-kit-icon.png" alt="Infra Kit icon" width="180">
</p>

# infra-kit

[![Quality](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/fridthjof-labs/infra-kit/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/fridthjof-labs/infra-kit)](https://github.com/fridthjof-labs/infra-kit/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Shell tools for encrypting, editing, and using secrets with SOPS and age.
I built infra-kit to share these operations across infrastructure repositories.
The tools are vendored into each repository, pinned by version and digest.

- `encrypt.sh` encrypts a file and removes the plaintext on success.
- `edit-encrypted.sh` edits a private temporary copy and encrypts it back.
- `with-decrypt.sh` streams decrypted input to a command through a one-use FIFO.

## Get started

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
  --vendor-dir infra/hack/vendor/infra-kit
```
<!-- x-release-please-end -->

Commit both `infra/hack/vendor/infra-kit/` and `infra/hack/vendor/infra-kit.lock`.
The lock records the version and payload digest. Check the vendored files with:

```bash
bash infra/hack/vendor/infra-kit/bootstrap/verify.sh infra/hack/vendor/infra-kit
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
kit=infra/hack/vendor/infra-kit
umask 077
printf 'example = "hello"\n' > infra/example.tfvars
bash "$kit/hack/encrypt.sh" infra/example.tfvars
bash "$kit/hack/with-decrypt.sh" CONFIG=infra/example.tfvars.enc \
  -- bash -c 'cat "$CONFIG"'
```
<!-- encryption-quickstart:end -->

The example prints the harmless value to your terminal. For real secrets, pass
the FIFO to the program that needs them. Each FIFO must be read once: a second
read blocks, and leaving one unread makes the command fail. A receiving program
can still log or persist its input.

To edit the encrypted file:

```bash
bash "$kit/hack/edit-encrypted.sh" infra/example.tfvars.enc
```

## Upgrading

The next release removes OpenTofu orchestration, repository scanning, project
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
