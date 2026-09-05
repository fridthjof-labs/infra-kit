# The OpenTofu standard

How every infra-kit repository runs OpenTofu. Up to v0.2 the kit owned only
encryption and vendoring, and each consumer hand-wrote its own driver; three
repositories produced three dialects and two of the copies broke the same way
(a script moved into the vendor directory and a caller kept the old path).
From v0.3 the kit owns the execution layer too. A consumer states its layout;
everything else is derived.

## Layout

```
repo/
  Makefile                   thin facade; declares the layout, nothing else
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

`bootstrap/scaffold.sh` writes exactly this into an empty repository — one
command, then replace the recipients and encrypt the operations file. Existing
repositories keep their directory names (`infra/` instead of `tofu/` is fine);
the Makefile's exported `INFRA_KIT_*` variables are the source of truth, not
the names.

## One command per intent

| Intent | Command | What actually runs |
| --- | --- | --- |
| Validate without production credentials | `make validate` | `verify.sh` (vendored bytes) → `scan-repo.sh` (no plaintext secrets, keys, state) → `tofu-validate.sh` (fmt, lock-file init, validate per root) |
| See a change | `make plan ROOT=x` | `tofu-run.sh x plan` |
| Ship a change | `make apply ROOT=x` | `tofu-run.sh x apply` (state snapshot first) |
| Snapshot state | `make backup ROOT=x` | `tofu-run.sh x backup` |
| Touch a secret | `make edit ROOT=x` / `make edit-ops` | `edit-encrypted.sh` |

`tofu-run.sh` is the only path to production state, local and CI alike. It
decrypts the operations file through a one-use FIFO, validates the ops
contract and the consumer's `INFRA_KIT_OPS_HOOK`, writes the backend config
for the derived state key, runs `tofu init -reconfigure`, snapshots state
before an apply, and streams root secrets as a `-var-file` FIFO. Plaintext
never touches disk.

## State

- Backend: an S3-compatible object store (Cloudflare R2 in every current
  consumer), native lockfile locking, path-style addressing. Every invariant
  backend setting is committed in the root's `backend "s3" {}` block; only
  bucket, key, and endpoint come from the operations file at init.
- Keys are derived: `INFRA_KIT_STATE_PREFIX/<root>/production.tfstate`. A
  root adopted with a pre-convention key pins it in a `state-key` file
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

The scaffolded workflow is the reference: validation on every PR and push
with no credentials; plan and apply are explicit `workflow_dispatch` against
the `Production` environment, apply additionally restricted to `main`. CI
holds exactly one secret — `SOPS_AGE_KEY`, the repository's dedicated age
identity — because the operations file already carries everything else. The
dispatch is the human gate; actions are pinned to commit SHAs.

## What stays the consumer's

The roots themselves, provider choice and versions, the ops hook, the
`.sops.yaml` recipient set, and any repository-specific automation. The kit
never learns provider specifics: a new cloud is a new ops-file entry and new
`.tf`, not a kit change.

## Migrating an existing consumer

1. `make sync-hack INFRA_KIT_VERSION=<v0.3.x>`.
2. Move each root under the tofu dir (single-root repositories: one `git mv`
   of the `.tf` files into a named subdirectory; state is untouched).
3. Pin each adopted root's existing key in `state-key`.
4. Fold backend config and credentials into `ops.env.enc`
   (`make edit-ops`); delete the per-env encrypted backend file, the local
   driver scripts, and their CI plumbing.
5. Replace driver Makefile targets with the kit ones (the scaffold's Makefile
   is the reference), re-run `make validate`, then one CI `plan` per root
   before trusting `apply` again.
