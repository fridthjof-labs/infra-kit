# Encryption key bootstrap (macOS + Linux)

Create an operator identity, verify it, then configure the scaffold's recipients.
Never overwrite an existing identity when following this guide.

Install [age](https://github.com/FiloSottile/age#installation) and
[SOPS](https://github.com/getsops/sops#installation) using their supported packages
or release binaries. On macOS, the Homebrew command below installs both. On
Linux, follow the upstream installation pages rather than assuming every
release of your distribution packages SOPS and the hardware plugin.

```bash
umask 077
mkdir -p "$HOME/.config/sops/age"
```

## 1. Choose the operator identity

### macOS: Secure Enclave

Requires a Mac with Secure Enclave and configured biometrics. The identity is
bound to this Mac; the separate recovery recipient below is essential.

```bash
brew install age age-plugin-se sops
age-plugin-se keygen --access-control=any-biometry -o "$HOME/.config/sops/age/secure-enclave.txt"
chmod 600 "$HOME/.config/sops/age/secure-enclave.txt"
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/secure-enclave.txt"
export AGE_RECIPIENT="$(age-plugin-se recipients -i "$SOPS_AGE_KEY_FILE")"
```

See [age-plugin-se](https://github.com/remko/age-plugin-se#usage) for access-control options.

### Linux: YubiKey PIV

`age-plugin-yubikey` uses **PIV**, not FIDO2. Upstream supports YubiKey 4 and 5
series; FIDO2-only security keys, including the blue Security Key by Yubico,
do not work. Check the [supported hardware](https://github.com/str4d/age-plugin-yubikey#manual-setup-and-technical-details)
before choosing this path.

Install [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey#installation)
and your distribution's `pcscd` service, then start it:

```bash
sudo systemctl enable --now pcscd
age-plugin-yubikey
```

Use the plugin's interactive setup to select the token and an unused slot,
configure PIN/touch policy, and save the identity to
`~/.config/sops/age/fido2.txt`. This filename is retained for compatibility with
existing infra-kit consumers; it does not describe the protocol. If you already
have a configured identity, reuse it rather than generating a replacement.

```bash
chmod 600 "$HOME/.config/sops/age/fido2.txt"
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/fido2.txt"
age-plugin-yubikey --list
```

Copy the public recipient for that identity from the list into this variable:

```bash
export AGE_RECIPIENT='REPLACE_WITH_YOUR_PUBLIC_RECIPIENT'
```

### Software identity (either platform)

With age and SOPS installed, this path requires no hardware plugin:

```bash
age-keygen -o "$HOME/.config/sops/age/keys.txt"
chmod 600 "$HOME/.config/sops/age/keys.txt"
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
export AGE_RECIPIENT="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
```

An explicit `SOPS_AGE_KEY_FILE` overrides infra-kit's platform default. Keep it
set in the shell where you run infra-kit. An explicit `SOPS_AGE_KEY` takes
precedence over the file, so unset it when testing a local identity.

## 2. Verify encryption and decryption

Run this with `AGE_RECIPIENT` and `SOPS_AGE_KEY_FILE` from the selected path.
It encrypts a harmless test value with SOPS and requires an exact decrypted
match. Hardware decryption may prompt for Touch ID, a PIN, or a touch.

<!-- key-roundtrip:begin -->
```bash
(
  set -eu
  unset SOPS_AGE_KEY
  : "${AGE_RECIPIENT:?set the public recipient}"
  : "${SOPS_AGE_KEY_FILE:?set the identity file}"
  umask 077
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/infra-kit-key-check.XXXXXX")"
  trap 'rm -rf -- "$probe_dir"' EXIT
  printf 'probe: infra-kit-key-check\n' > "$probe_dir/probe.yaml"
  sops --encrypt --age "$AGE_RECIPIENT" --input-type yaml --output-type yaml \
    "$probe_dir/probe.yaml" > "$probe_dir/probe.enc"
  sops --decrypt --input-type yaml --output-type yaml \
    "$probe_dir/probe.enc" > "$probe_dir/decoded.yaml"
  cmp "$probe_dir/probe.yaml" "$probe_dir/decoded.yaml"
  printf 'SOPS encryption/decryption verified\n'
)
```
<!-- key-roundtrip:end -->

## 3. Configure the three scaffold recipients

Replace the placeholders in `infra/.sops.yaml` (or `tofu/.sops.yaml` if you used
the scaffold's default directory):

- Operator: the public `AGE_RECIPIENT` verified above.
- CI: a separate software identity dedicated to this repository. Generate it
  with `age-keygen -o /secure/path/repository-ci.txt` and obtain its public
  recipient with `age-keygen -y /secure/path/repository-ci.txt`. Store the
  private identity as the repository's `Production` environment secret
  `SOPS_AGE_KEY`.
- Recovery: another software identity, stored offline independently of the
  operator device and CI. Generate it on the recovery system and transfer only
  its public recipient into the repository.

Verify each identity with the round trip before encrypting real data. Commit
only public recipients and encrypted files; keep private identities outside the
repository. Return to the [quickstart](../README.md#start-a-new-infrastructure-repository)
to encrypt the operations file and run validation and the first plan.
