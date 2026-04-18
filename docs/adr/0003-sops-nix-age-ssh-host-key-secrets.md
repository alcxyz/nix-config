# ADR-0003: Use sops-nix with age decryption via SSH host key

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/common/default.nix`, `flake.nix`

## Context

NixOS systems need a mechanism to decrypt secrets at activation time, ensuring plaintext values never enter the Nix store. A decryption identity is also needed — something the machine possesses at boot without manual intervention.

Several tools exist for runtime secret decryption (agenix, sops-nix, ragenix). For the identity, options include a dedicated age key (requires provisioning), the machine's SSH host key (auto-generated on first boot), or a hardware key (requires physical presence).

sops supports structured YAML with multiple recipients per file, partial file decryption, and secret templating — capabilities useful when a single secrets file contains values for different services.

## Decision

Use `sops-nix` for runtime secret decryption, with the machine's SSH host ed25519 key as the age identity:

```nix
sops = {
  defaultSopsFile = "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml";
  age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
};
```

Each host's SSH host public key is used as the age recipient when encrypting secrets in nix-secrets. sops-nix decrypts at activation and places secrets at module-defined paths with correct ownership and permissions.

## Alternatives Considered

- **agenix / ragenix** — Considered. Simpler tooling, but secrets are single-recipient per file and lack sops's structured YAML capabilities (key access control per secret, templating). sops-nix's richer feature set was preferred for a multi-host, multi-service setup.
- **Dedicated age key per host** — Rejected. Requires provisioning and securely storing a separate key file on each machine. The SSH host key already exists on every NixOS machine from first boot with no extra steps.
- **YubiKey age identity for sops** — Rejected for sops decryption specifically. Requires physical hardware present at every activation, including automated rebuilds. YubiKey identity is reserved for ZFS unlock where physical presence is acceptable (see ADR-0004).
- **vault-agent** — Rejected. Requires running and maintaining a Vault server; far more operational overhead than warranted for a personal multi-host setup.

## Consequences

- No separate key to provision on fresh installs — the SSH host key is generated automatically on first boot and immediately usable as an age identity.
- If a host's SSH host key is rotated or regenerated (e.g. full reinstall without preserving `/etc/ssh`), all secrets encrypted to that host must be re-encrypted with the new key in nix-secrets before the next deployment.
- sops YAML files support multiple recipients, so any secret can be encrypted to several host keys simultaneously, enabling shared secrets across hosts without duplication.
- The YubiKey age identity is intentionally separate from sops — do not add `age.yubikey*` paths to `age.sshKeyPaths`. That identity is used only for ZFS unlock (ADR-0004).
