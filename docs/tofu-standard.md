# Running OpenTofu

The execution scripts share the work of loading encrypted credentials,
initializing a backend, and backing up state before apply. Your repository
supplies the roots, layout, and provider configuration.

## Layout

```
repo/
  Makefile                   commands and INFRA_KIT_* layout variables
  mise.toml                  local tool pins (opentofu, sops)
  hack/vendor/infra-kit/     the vendored kit, digest-locked
  tofu/                      INFRA_KIT_ROOT: .sops.yaml + encrypted files
    .sops.yaml
    ops.env.enc              shared operations file (see below)
    <root>/                  one directory per OpenTofu root
      *.tf                   backend "s3" {} with every invariant setting
      secrets.auto.tfvars.enc   optional root-scoped secrets
      ops.env.enc               optional overlay over the shared ops file
      state-key                 optional pinned state key for adopted roots
```

Create the layout and use the [consumer Makefile](consumer.md) to wire up the
commands. Existing repositories can keep their directory names (`infra/`
instead of `tofu/` is fine); the exported `INFRA_KIT_*` variables set the paths.

## Commands

| Intent | Command | What actually runs |
| --- | --- | --- |
| Validate without production credentials | `make validate` | `verify.sh` (vendored bytes) → `scan-repo.sh` (no plaintext secrets, keys, state) → `tofu-validate.sh` (fmt, lock-file init, validate per root) |
| See a change | `make plan ROOT=x` | `tofu-run.sh x plan` |
| Ship a change | `make apply ROOT=x` | `tofu-run.sh x apply` (state snapshot first) |
| Snapshot state | `make backup ROOT=x` | `tofu-run.sh x backup` |
| Touch a secret | `make edit ROOT=x` / `make edit-ops` | `edit-encrypted.sh` |

`tofu-run.sh` can be used locally and in CI. It
decrypts the operations file through a one-use FIFO, validates the ops
contract and the consumer's `INFRA_KIT_OPS_HOOK`, writes the backend config
for the derived state key, runs `tofu init -reconfigure`, snapshots state
before an apply, and streams root secrets as a `-var-file` FIFO. Plaintext
never touches disk.

## State

- Backend: an S3-compatible object store, native lockfile locking, and
  path-style addressing. Static backend settings are committed in the root's
  `backend "s3" {}` block; only
  bucket, key, and endpoint come from the operations file at init.
- Keys are derived: `INFRA_KIT_STATE_PREFIX/<root>/production.tfstate`. A
  root with an existing key can pin it in a `state-key` file
  instead of migrating a state object over a name.
- R2 has no bucket versioning, so an apply pulls a checksummed snapshot into
  `state-backups/` (gitignored) first. A root's very first apply has nothing
  to pull: `SKIP_STATE_BACKUP=1`, once.

## Secrets

Two encrypted planes, one mechanism (SOPS + age, hardware identities local,
a dedicated per-repository key in CI, an offline recovery key — see
`encryption-bootstrap.md`):

- **`ops.env.enc`** — the operations file, shared by every root: state bucket,
  endpoint, bucket-scoped access keys, provider credentials, shared `TF_VAR_*`
  values. Sourced with `set -a` so a run never depends on what the calling
  shell happened to export. The kit requires `INFRA_KIT_STATE_BUCKET`,
  `INFRA_KIT_STATE_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`;
  the consumer's `INFRA_KIT_OPS_HOOK` enforces the rest and receives
  `INFRA_KIT_TOFU_ROOT`, so one exceptional root does not fork the driver —
  it gets an `ops.env.enc` overlay in its root directory instead.
- **`secrets.auto.tfvars.enc`** — per root, for a credential only that root
  uses. Streamed as a one-use `-var-file`; a plaintext twin refuses the run
  because tofu would auto-load it silently.

## CI

Define CI in the consumer repository. Run validation on pull requests without
production credentials. If you run plan/apply in Actions, scope the dedicated
`SOPS_AGE_KEY` identity to a protected environment, restrict apply to your default
branch, and require approval before it runs. Keep third-party actions pinned to
commit SHAs. Infra-kit does not supply or configure these workflows.

## Repository configuration

Your repository controls the roots, provider choice and versions, ops hook,
`.sops.yaml` recipient set, and any additional automation. Provider credentials
come from the operations file; provider configuration stays in the `.tf` files.

## Migrating an existing consumer

1. Vendor a reviewed release using the [consumer guide](consumer.md).
2. Move each root under the tofu dir (single-root repositories: one `git mv`
   of the `.tf` files into a named subdirectory; state is untouched).
3. Pin each adopted root's existing key in `state-key`.
4. Fold backend config and credentials into `ops.env.enc`
   (`make edit-ops`); delete the per-env encrypted backend file, the local
   driver scripts, and their CI plumbing.
5. Replace driver Makefile targets with the [consumer Makefile](consumer.md), re-run `make validate`, then one CI `plan` per root
   before trusting `apply` again.
