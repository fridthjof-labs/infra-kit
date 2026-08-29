# Encryption key bootstrap (macOS + Linux)

Infra-kit defaults to:

- macOS: `~/.config/sops/age/secure-enclave.txt` (Touch ID)
- Linux: `~/.config/sops/age/fido2.txt` (FIDO2/YubiKey)

## 1) Common

```bash
mkdir -p "$HOME/.config/sops/age"
```

## 2) macOS

```bash
brew install age age-plugin-se sops
age-plugin-se keygen --access-control=any-biometry -o "$HOME/.config/sops/age/secure-enclave.txt"
chmod 600 "$HOME/.config/sops/age/secure-enclave.txt"
```

## 3) Linux (choose one)

### Option A — FIDO2 (default path)

```bash
# Debian/Ubuntu
sudo apt install -y age sops age-plugin-yubikey pcscd

# Fedora
sudo dnf install -y age sops age-plugin-yubikey pcsc-lite ccid

# Arch Linux
sudo pacman -S --noconfirm age sops pcsclite ccid
paru -S age-plugin-yubikey        # if using AUR

# Nix
nix profile install nixpkgs#age nixpkgs#sops nixpkgs#age-plugin-yubikey

sudo systemctl enable --now pcscd
age-plugin-yubikey --generate --slot 1 > "$HOME/.config/sops/age/fido2.txt"
chmod 600 "$HOME/.config/sops/age/fido2.txt"
```

If your package manager does not expose `age-plugin-yubikey`, install from upstream.

### Option B — software fallback (no FIDO token)

```bash
# Debian/Ubuntu
sudo apt install -y age sops

# Fedora
sudo dnf install -y age sops

# Arch Linux
sudo pacman -S --noconfirm age sops

# Nix
nix profile install nixpkgs#age nixpkgs#sops

age-keygen -o "$HOME/.config/sops/age/keys.txt"
chmod 600 "$HOME/.config/sops/age/keys.txt"
```

Use with explicit env:

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

## 4) Use default/alternate paths

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/fido2.txt"
# or
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/secure-enclave.txt"
```

## 5) Validate

```bash
ls -l "$HOME/.config/sops/age/"
```
