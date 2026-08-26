# Security policy

## Reporting a vulnerability

Report privately through [GitHub Security Advisories](https://github.com/fridthjof-labs/infra-kit/security/advisories/new).
Please do not open a public issue for a vulnerability.

Include what an attacker gets, not just what looks wrong. This is the tooling
that decrypts production secrets on a maintainer's machine and in CI, so
anything that puts plaintext somewhere it can be read later, or that makes a
consumer run bytes its lock does not describe, is in scope and will be treated
as urgent.

## In scope

- Plaintext reaching disk, a surviving temporary file, or a FIFO another local
  user can read
- Plaintext leaking through a command line, an environment variable, an error
  message, or a shell trace
- A failed or aborted edit leaving the encrypted file damaged, or leaving the
  decrypted copy behind
- Temporary-directory handling: predictable paths, permissive modes, or symlink
  following that lets another local user redirect a write
- `sync.sh` writing outside `--vendor-dir`, or vendoring a payload that does not
  match the digest it then records
- `verify.sh` reporting a match for bytes that differ from the lock

## Out of scope

- The first fetch of `bootstrap/sync.sh`. It arrives before there is a lock to
  check it against; [docs/consumer.md](docs/consumer.md) says to read it first.
- Someone with commit access to a consumer repository editing a vendored file
  and its lock in the same commit. The lock guards against accident; the
  committed diff is the real control.
- Vulnerabilities in `sops`, `age`, or OpenTofu themselves — report those
  upstream.
- Key management in a consumer repository: which recipients are in `.sops.yaml`,
  and who holds those identities, is the consumer's decision.
