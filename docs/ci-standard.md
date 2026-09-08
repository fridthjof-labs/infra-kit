# Shared CI baseline

Keep build commands in the repository's Makefile or mise tasks. GitHub Actions
chooses when and where to run them; changing providers must not require rewriting
the tests. The Go and TypeScript scaffolds include this workflow validation gate.
Infrastructure and other callers can add it to their existing CI:

```yaml
jobs:
  workflow-policy:
    uses: fridthjof-labs/infra-kit/.github/workflows/workflow-ci.yml@<reviewed-40-character-commit>
```

The gate runs actionlint 1.7.12 and zizmor 1.30.0. Linux amd64 and arm64 downloads
are checked against committed SHA-256 digests. It validates workflow syntax,
expressions and dependencies, then rejects medium/high security findings with
high confidence, including mutable action references, blanket App tokens and
shell injection. Security analysis includes composite actions. It needs only
repository read access and does not execute the caller's build configuration.

The security gate runs offline, ignores local suppression configuration, and
does not claim to replace dependency scans, secret scans, code review or runtime
isolation. Low-confidence findings need review rather than blanket suppression
or automatic changes to publishing workflows. ShellCheck and Python lint belong
to the repository's language checks and are not implicitly enabled by host tools.

## Keep the merge gate honest

Run workflow validation on every pull request; do not use workflow-level path
filters for a required check. Expensive language jobs can use tested change
selection, with the final required job checking both the decision and the result.
Keep existing required-check names stable. An aggregator must require
`needs.workflow-policy.result == 'success'`, run with `!cancelled()`, and reject
an unexpected skip. A skipped dependency alone is not a failed required check.
Alternatively require the reusable job's full check name in the merge policy.

## Scheduling and permissions

- Give each job a timeout. Cancel superseded pull-request checks using a
  workflow-and-ref concurrency group. Never cancel an in-progress release,
  deployment or infrastructure apply to save CI minutes.
- Default to `contents: read`. Grant writes only to the job that publishes.
  Set explicit `permission-*` inputs on GitHub App token creation; module
  downloads need `permission-contents: read`, not the App's installation scope.
- Pin actions and reusable workflows to reviewed commit SHAs. Review and update
  validator versions and their release digests together.
- Keep deployment credentials in deployment jobs and environments, after checks.
  Pass dispatch inputs through environment variables and quote shell arguments.
- Retain caches keyed by lockfiles/toolchains; cache dependencies and compiler
  output, never credentials. Shared runners need isolated job credentials and
  bounded per-repository caches. Check cache hits before claiming an improvement.

## Runner portability

`runner` accepts a JSON label or label array; the default is GitHub's Linux
runner. `runner-labels` accepts the JSON array of custom self-hosted labels that
actionlint should recognize. The caller owns routing: untrusted fork code must
never reach a persistent privileged runner. Public projects can keep hosted
compute while trusted private Linux jobs use their own runners. Linux ARM64
cannot validate native macOS/Windows integration or x86-only dependencies.

Keep one heavy build per small host and a bounded lightweight lane for gates.
More registered runners do not create more CPU. Track queue time separately
from execution time before adding capacity or changing CI providers.

References: [GitHub secure use](https://docs.github.com/en/actions/reference/security/secure-use),
[reusable workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations),
[zizmor audits](https://docs.zizmor.sh/audits/).
