# Upgrading from 0.4.x

Version 0.5 focused infra-kit on encryption and verified vendoring.
That release retained the encryption paths and behavior.

## Reusable workflows

The Go, TypeScript, secret-scan, and workflow-validation reusable workflows
are removed. A caller pinned to an older commit or release can continue to
use that revision. Do not update that pin to a release that removes its file.
Move the checks your repository needs into its own workflow before dropping
the old reference. Keep secret scanning and workflow validation where they
protect your project; removing the shared wrapper does not replace those checks.

## Project generators

The OpenTofu, Go, and TypeScript generators are removed. Existing generated repositories
keep their files; new projects should define their own toolchain and CI.

## OpenTofu and repository scanning

`hack/tofu-run.sh`, `hack/tofu-validate.sh`, `hack/scan-repo.sh`, and the two
internal OpenTofu helpers are removed. Their Makefile targets will fail after
an upgrade unless migrated first. Keep your existing pin until that work is done.

Move the needed commands into consumer-owned scripts. Preserve backend locking,
existing state keys, pre-apply backups, credential validation, and checks for
plaintext secrets and state files. Replace repository scanning with checks
owned by the consumer; encryption and payload verification do not replace it.
Validate locally and review a plan against the existing backend before applying.
This release does not migrate state or change any deployed infrastructure.

The `ops.env` encryption compatibility rule remains: Bash syntax is checked,
and the custom validation hook is bypassed. No backend schema is validated.

## Shared Make interface

The next release moves `hack/` to `scripts/` and adds `make/secrets.mk`.
There are no changes to ciphertext formats, recipients or state operations.
The old installer copies only `hack/`, so download the new release's
`bootstrap/sync.sh` first and run it with that same release version. Do not
use the v0.5 vendored installer for this transition. Existing pinned copies
continue to work until deliberately upgraded.

Update direct calls from `<vendor>/hack/` to `<vendor>/scripts/`, including
any imports of `lib/common.sh`. Replace duplicated encryption recipes with the
include shown in [the consumer guide](consumer.md). Preserve your file defaults
and validation hooks; operations-file hooks use `INFRA_KIT_OPS_VALIDATE_HOOK`.
`sync-hack` and `verify-hack` can remain local aliases for `sync-infra-kit` and
`verify-infra-kit` so existing automation keeps working.

New projects can vendor into `infra/vendor/infra-kit`. Existing vendor locations
remain supported; relocating them is optional and independent of this upgrade.
