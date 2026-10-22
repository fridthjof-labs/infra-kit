# Reusable GitHub Actions workflows

These workflows are optional. They run checks for repositories using the kit's
scaffolds, or can be called from an existing workflow.

| Workflow | What it runs |
| --- | --- |
| `go-ci.yml` | Lint, tests across an OS matrix, and optional race, vulnerability, and minimum-version checks |
| `ts-ci.yml` | The repository's mise setup and check tasks |
| `workflow-ci.yml` | GitHub Actions syntax and security checks |

The [Go and TypeScript scaffolds](bootstrap.md) generate callers with the required
inputs. To add workflow validation on its own:

```yaml
jobs:
  workflows:
    uses: fridthjof-labs/infra-kit/.github/workflows/workflow-ci.yml@<reviewed-40-character-commit>
```

`workflow-ci.yml` runs actionlint and zizmor with pinned versions and verified
download digests. It checks workflow syntax, expressions, and medium/high
security findings with high confidence, including mutable action references and
shell injection. Composite actions are included. It runs offline after installing
the validators and ignores local suppression configuration. It does not execute
the caller's build configuration or replace secret and dependency scanning.

## Runners and required checks

`workflow-ci.yml` defaults to GitHub-hosted Linux. Its `runner` input accepts a
JSON label or label array; `runner-labels` lists additional self-hosted labels
for actionlint. Only route trusted code to persistent self-hosted runners.

If you make workflow validation a required check, run its caller on every pull
request. Workflow-level path filters can leave a required check pending. When an
aggregating job is required instead, have it run even after a dependency fails
and accept only successful results, including workflow validation.

See each [workflow's inputs](../.github/workflows/) for configuration details.
