# infra-kit

The shared operating layer for encrypted OpenTofu infrastructure, vendored into
each consumer repository rather than copied by hand.

Three organisations were running near-identical copies of the same SOPS
tooling: 501 lines of shell, of which 26 differed. `encrypt.sh` was
byte-identical. `edit-encrypted.sh` differed by one line — a temporary
directory prefix. That is copy-paste that has begun to rot, and the failure
mode is silent: a fix lands in one repository and the others keep the bug.

## What is shared, and what is not

The split follows what the differences actually were, not what looked tidy:

| Kind | Example | Where it lives |
| --- | --- | --- |
| **Upstream drift** | ShellCheck compatibility comments, cleanup fixes | Here. One copy, everyone gets the fix. |
| **Configuration** | Temporary-file prefix, default secrets filename, editor | Here, as an environment variable. |
| **Repository adapter** | Which secret keys are required, Tofu roots, state backup, multi-root layout | The consumer. Never here. |

So `hack/` holds the encryption engine — encrypting, safe editing, FIFO
decryption, key selection, cleanup — and nothing that knows what a particular
repository's secrets mean.

## Scripts

| Script | Purpose |
| --- | --- |
| `encrypt.sh` | Encrypt a plaintext file to `.enc` and remove the plaintext |
| `edit-encrypted.sh` | Decrypt to a mode-0600 temporary file, edit, validate, re-encrypt |
| `with-decrypt.sh` | Stream secrets to a command through FIFOs; plaintext never becomes a file |

## Consumers state their own root

The original scripts derived the infrastructure directory from their own
location (`${BASH_SOURCE[0]}/..`). Vendored into
`infra/hack/vendor/infra-kit/`, that resolves to `infra/hack/vendor` and looks
for the wrong `.sops.yaml`.

So there is no location inference at all. The consumer sets `INFRA_KIT_ROOT`,
and a missing one is a named error rather than a confusing not-found:

```make
INFRA_KIT       := infra/hack/vendor/infra-kit
export INFRA_KIT_ROOT           := $(CURDIR)/infra
export INFRA_KIT_TMP_PREFIX     := my-org
export INFRA_KIT_VALIDATE_HOOK  := $(CURDIR)/infra/hack/validate-secrets.sh
```

| Variable | Meaning |
| --- | --- |
| `INFRA_KIT_ROOT` | Directory holding `.sops.yaml` and the encrypted files. Required. |
| `INFRA_KIT_TMP_PREFIX` | Prefix for temporary directories. Default `infra-kit`. |
| `INFRA_KIT_DEFAULT_SECRETS` | Default secrets filename. Default `prod.secrets.auto.tfvars`. |
| `INFRA_KIT_VALIDATE_HOOK` | Executable run against plaintext before re-encryption. Non-zero aborts the write. |
| `SOPS_AGE_KEY` / `SOPS_AGE_KEY_FILE` | Explicit identity. Otherwise the local Secure Enclave identity. |

## Vendoring, version and digest

`sync.sh` is the only command that touches the network. `verify.sh` is offline
and checks the committed bytes against `infra-kit.lock`:

```bash
# Upgrade: downloads, replaces the vendor directory, rewrites the lock.
bash infra/hack/vendor/infra-kit/../../../bootstrap/sync.sh \
  --version v0.1.0 --vendor-dir infra/hack/vendor/infra-kit

# Offline, part of `make validate`.
bash bootstrap/verify.sh infra/hack/vendor/infra-kit
```

The lock records both version and digest. Recording the version alone would
let a local edit to a vendored file pass unnoticed and become renewed drift —
the exact problem this repository exists to end. `verify.sh` fails on an edited
file, a deleted file, and an unvendored directory, each with the command that
fixes it.

`validate`, `plan`, and `apply` never download anything. An upgrade is a commit
you review, not something that happens during a deploy.

## Adopting it

See [docs/consumer.md](docs/consumer.md).

## Development

```bash
make check     # bash -n, shellcheck, and the test suite
```

The tests use a real `age` identity and a real `sops`, and assert the
properties that matter rather than the code paths: no plaintext adjacent to the
output, a failed edit leaving the encrypted file untouched, FIFO cleanup,
signal handling, and both the CI key and the local key-file path. They run the
scripts from a vendored directory, so the relocation bug above cannot come
back.

## Not here

Cloudflare OpenTofu modules. Dykkerværkstedet pins Cloudflare provider 4.52 and
Fridthjof Labs pins 5.x, so a shared module needs that boundary resolved first.
They arrive once two consumers demonstrably share a resource contract, not
before.

## Licence

MIT.
