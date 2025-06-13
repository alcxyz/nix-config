# Secret Management Workflow

This document outlines the secure and declarative workflow for managing secrets within this Nix flake repository. The primary goal is to enable secrets to be version-controlled safely in Git while maintaining a clean, user-friendly management process.

The core philosophy is a strict separation of concerns:
*   **Human Interaction:** Managed by `gopass` and a personal GPG key (YubiKey).
*   **Machine Deployment:** Managed by `sops` and host-specific SSH keys.

## Core Components

| Tool | Role |
| :--- | :--- |
| 🔑 **`gopass`** | **The Single Source of Truth.** This is the user-facing password manager where all plaintext secrets are stored. It's encrypted using the administrator's GPG key, making it ideal for interactive use. |
| 🔒 **`sops`** | **The Encryption Layer.** This tool creates the `secrets/secrets.yaml` file that is committed to Git. This file is encrypted for multiple recipients: the administrator's GPG key (for editing) and each host's unique SSH key (for deployment). |
| 🤖 **`sops-nix`** | **The Deployment Engine.** This NixOS/nix-darwin module decrypts `secrets/secrets.yaml` *during the system build*. It uses the host's own private SSH key, requiring no human interaction or passphrases on the server. |
| 🌉 **`scripts/update-secrets.sh`** | **The Bridge.** This crucial script automates the process of reading secrets from `gopass` and feeding them into `sops` to generate the final encrypted file. |

---

## Day-to-Day Workflow

This is the standard process for adding or changing a secret.

### 1. Add or Edit the Secret in `gopass`

Use the `gopass` command-line tool to manage the secret's content. This is the only place you should ever handle plaintext secrets. Use a consistent naming scheme.

**To add a new secret:**
```bash
gopass insert nixos/services/new-service/api_key
```

**To edit an existing secret:**
```bash
gopass edit nixos/services/pihole/password
```

### 2. Update the Encrypted SOPS File

Run the bridge script from the root of the repository. This script reads the latest values from `gopass` and regenerates the encrypted `secrets/secrets.yaml` file.

```bash
./scripts/update-secrets.sh
```

### 3. Commit and Deploy

Commit the updated `secrets/secrets.yaml` file to Git. The `.gitignore` file is configured to prevent the unencrypted version from ever being committed.

```bash
git add secrets/secrets.yaml
git commit -m "Update secrets for new-service"
```

Finally, deploy the changes to the relevant host:
```bash
sudo nixos-rebuild switch --flake .#nux
```

---

## Adding a New Host

When adding a new host (e.g., `server-02`) to the flake, you must make it a valid recipient for the secrets.

### 1. Generate a Permanent Host Key

On your local machine, generate a new, permanent SSH key pair for the host.

```bash
mkdir -p persistent-keys
ssh-keygen -t ed25519 -f ./persistent-keys/server-02_host_key -N "" -C "root@server-02"
```

### 2. Store the Private Key in `gopass`

Store the new host's *private* key in `gopass`.

```bash
gopass insert -m nixos/hosts/server-02/ssh_host_ed25519_key < ./persistent-keys/server-02_host_key
```

### 3. Add the Public Key to SOPS Configuration

Edit the `.sops.yaml` file and add the new host's *public* key (from `persistent-keys/server-02_host_key.pub`) to the `age:` list.

```yaml
# .sops.yaml
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    pgp: YOUR_GPG_FINGERPRINT
    age:
      - "ssh-ed25519 AAAA... root@nux"
      - "ssh-ed25519 AAAA... root@xyz"
      - "ssh-ed25519 AAAA... root@server-02" # <-- Add new host here
```

### 4. Update the Bridge Script

Edit `scripts/update-secrets.sh` to include the new host key in the generated `secrets.yaml` file.

```bash
# scripts/update-secrets.sh
# ...
cat > "${SECRETS_FILE}" << EOF
# ... other secrets
nux_host_key_private: |
  $(gopass show -n nixos/hosts/nux/ssh_host_ed25519_key)
server-02_host_key_private: |
  $(gopass show -n nixos/hosts/server-02/ssh_host_ed25519_key)
EOF
# ...
```

### 5. Run the Script and Deploy

1.  Run `./scripts/update-secrets.sh` to re-encrypt the secrets for the new host.
2.  Commit the changes to `.sops.yaml`, `scripts/update-secrets.sh`, and `secrets/secrets.yaml`.
3.  Configure the new host's `configuration.nix` to use its SOPS-managed host key, as seen in `hosts/nux/configuration.nix`.
4.  Deploy to the new host.

## Security Considerations

*   **`.gitignore`:** The unencrypted `secrets/secrets.yaml` is explicitly ignored by Git. This is a critical safety measure.
*   **GPG Key:** Your personal GPG key is the master key for editing all secrets. Keep it secure.
*   **Host Keys:** The permanent host private keys are stored encrypted in `gopass` and again in `sops`. They are only ever decrypted in memory or in protected files during a NixOS build.
