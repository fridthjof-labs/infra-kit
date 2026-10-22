# Repository scaffolds

The scaffolds create a starting layout in an empty repository and refuse to
overwrite existing files. They pin tools in `mise.toml` and generate GitHub
Actions workflows. Existing repositories can use the [consumer guide](consumer.md)
to adopt just the parts they need.

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

Then follow [running OpenTofu](tofu-standard.md) and
[encryption key setup](encryption-bootstrap.md). When adopting an existing root,
verify that the first plan shows only the changes you expect. Unexpected creates
can mean the backend points at the wrong bucket or key; check before applying.

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

A service or daemon can add `cmd/<name>` and its own release workflow.

## TypeScript repository (website or app)

```bash
bash hack/vendor/infra-kit/bootstrap/scaffold-ts.sh \
  --node <version> --pm pnpm|bun --pm-version <version> --kit-ref <sha>
mise install && mise run setup && mise run check
```

The generated tasks run `package.json`'s `check` script. Define that script with
the checks your project needs, and match the package manager version to
`packageManager` in `package.json`.

## Review the generated files

Run the generated checks locally and review the workflow permissions before
committing. For infrastructure, configure the `Production` environment before
running plan or apply in GitHub Actions.

The Go and TypeScript scaffolds also write `.github/tidebot.yaml`. If you want
automated review commands and merging, install [Tidebot](https://github.com/fridthjof-labs/tidebot)
and create the configured labels. Otherwise, remove that file; it is not needed
to build or test the project.
