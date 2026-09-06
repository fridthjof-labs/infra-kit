# Bootstrap: one runnable path per repository type

Every repository type has one scaffold and one reusable workflow. The scaffold
writes the files; the reusable workflow is what CI runs, pinned by commit. A
version is stated once, in `mise.toml`, and CI installs it from there.

All paths start the same way, in an empty Git repository with
[mise](https://mise.jdx.dev/getting-started.html) installed:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/fridthjof-labs/infra-kit/main/bootstrap/sync.sh \
  -o /tmp/infra-kit-sync.sh
less /tmp/infra-kit-sync.sh
bash /tmp/infra-kit-sync.sh --version <release> --vendor-dir hack/vendor/infra-kit
```

`<release>` is the tag you are adopting. `--kit-ref` below is that tag's
commit (`git ls-remote https://github.com/fridthjof-labs/infra-kit <release>`):
reusable workflows are referenced by full SHA, because a tag can move.

## Infrastructure (OpenTofu + SOPS)

```bash
bash hack/vendor/infra-kit/bootstrap/scaffold.sh --state-prefix <org> --root <root>
```

Then the [operations-file contract](tofu-standard.md) and
[encryption key setup](encryption-bootstrap.md). The first `make plan` against
an adopted root must show `No changes`; many creates on a live root means the
backend points at the wrong bucket or key.

## Go module (library, service, daemon or CLI)

```bash
go mod init github.com/<org>/<name>
bash hack/vendor/infra-kit/bootstrap/scaffold-go.sh \
  --module github.com/<org>/<name> --go <floor> --kit-ref <sha> \
  [--private-modules a,b] [--test-os '["ubuntu-latest", "macos-latest"]']
go -C tools mod tidy
mise install && mise run check
```

`--go` is the floor `go.mod` declares; it lands in `mise.toml` and
`tools/go.mod` and CI's `consumer-readiness` job builds at exactly that
version. `--private-modules` names sibling private repositories the module
imports; CI then mints a scoped App token from `RELEASE_APP_ID` /
`RELEASE_APP_PRIVATE_KEY` before Go fetches. `--test-os` narrows the matrix to
the platforms that actually build.

A service or daemon adds its `cmd/<name>` and its own release workflow; the
baseline does not change. A desktop shell around the daemon adds a frontend
under `frontend/` with its own `mise.toml` entries for node and the package
manager, and calls `ts-ci.yml` from a second job.

## TypeScript repository (website or app)

```bash
bash hack/vendor/infra-kit/bootstrap/scaffold-ts.sh \
  --node <version> --pm pnpm|bun --pm-version <version> --kit-ref <sha>
mise install && mise run setup && mise run check
```

`package.json` must define a `check` script (lint, typecheck, test, build):
that one script is the definition of done locally and in CI. The package
manager version must equal `packageManager` in `package.json`.

## After any scaffold

1. Commit and push; open the first pull request.
2. Install the Tidebot GitHub App on the repository and create the labels its
   `.github/tidebot.yaml` refers to (`tidebot labels --repo <org>/<name>`).
3. Add the repository to the owner's settings-as-code root so its secrets and
   rulesets are a reviewed change from then on.
