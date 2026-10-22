# Upgrading from 0.4.x

The next release removes project generation and reusable CI from infra-kit.
The encryption commands, verified vendoring, and OpenTofu execution helpers
keep their existing paths and behavior.

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
