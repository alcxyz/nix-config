# ADR-0006: Four-tier module layering (common → role → service/hardware → per-host)

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/`, `hosts/`, `users/`

## Context

This repo manages four hosts across three architectures with significant shared configuration (users, SSH keys, Nix settings, audio, bluetooth) but diverging roles and hardware. Without structure, configuration either duplicates across hosts or becomes one tangled monolithic module that opts everything in everywhere.

## Decision

Configuration is organised into four tiers, composed via explicit `imports` in each host's `configuration.nix`:

**Tier 1 — Common base** (`modules/nixos/common/default.nix`): Applied to every host. Nix daemon settings, binary caches, SSH authorized keys, user/group definitions, core services (openssh, pipewire, bluetooth), sops-nix bootstrap, fonts, locale, keyboard, bootloader.

**Tier 2 — Role** (`modules/nixos/common/{desktop,server}.nix`): Applied by host function. `desktop.nix` adds Hyprland, display manager, GPU support, Docker with CDI, kanata, and desktop packages. `server.nix` adds distributed build config and server packages. Each host imports exactly one role module.

**Tier 3 — Service and hardware modules** (`modules/nixos/{services,hardware,virtualisation}/`): Opt-in, imported only by hosts that need them. Each module is self-contained — it defines its own sops secrets, systemd services, and package requirements. Examples: `nvidia.nix`, `amd.nix`, `zfs-autounlock`, `kvm/gpu-passthrough`.

**Tier 4 — Per-host** (`hosts/{hostName}/configuration.nix`): Imports the applicable tiers and adds host-specific values: networking, ZFS pool names, service parameters, hardware UUIDs, tmpfiles rules.

Home Manager mirrors this: `users/alc/common.nix` → `users/alc/linux/common.nix` → `users/alc/linux/{xyz,nux,rpi0}.nix`.

## Alternatives Considered

- **Flat per-host configs (full duplication)** — Rejected. Does not scale; common changes (SSH keys, Nix settings) require editing every host file independently.
- **Single monolithic shared module** — Rejected. Forces all configuration onto all hosts; cannot express role or service opt-in without conditional logic sprawl.
- **NixOS module system with `enable` options throughout** — Considered but kept minimal. Service modules use `enable` options internally, but the tier structure provides coarse composition without forcing every feature to be an explicit option in a global config.

## Consequences

- Adding a new host requires only writing `hosts/{name}/configuration.nix` importing the appropriate tiers. No changes to shared modules needed.
- Service modules are independently composable — they make no assumptions about which other modules are present.
- The full config of any host requires following imports across tiers; it is not visible from a single file.
- When adding configuration: all-host values → `common/default.nix`; role values → appropriate role module; service/hardware → new or existing service module; host-specific → `hosts/{name}/configuration.nix`. Never add per-host values to shared modules.
