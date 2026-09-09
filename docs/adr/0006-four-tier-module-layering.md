# ADR-0006: Four-tier module layering (common → role → service/hardware → per-host)

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/`, `hosts/`, `users/`

## Context

This repo manages four hosts across three architectures with significant shared configuration (users, SSH keys, Nix settings, audio, bluetooth) but diverging roles and hardware. Without structure, configuration either duplicates across hosts or becomes one tangled monolithic module that opts everything in everywhere.

## Decision

Configuration is organised into four tiers, composed via explicit `imports` in each host's `configuration.nix`:

**Tier 1 — Common base** (`modules/nixos/common/default.nix`): Applied to every host. Nix daemon settings, binary caches, SSH authorized keys, user/group definitions, core services (openssh, pipewire, bluetooth), sops-nix bootstrap, fonts, locale, keyboard, bootloader.

**Tier 2 — Role** (`modules/nixos/common/{desktop,server}.nix`): Applied by host function. `desktop.nix` adds Hyprland, the display manager, Docker defaults, kanata, and desktop packages. GPU driver selection, display identity, and GPU container policy are supplied by explicit host hardware/private modules. `server.nix` adds server packages and server defaults. Optional capabilities such as distributed-build client credentials live in separate explicit modules.

**Tier 3 — Service and hardware modules** (`modules/nixos/{services,hardware,virtualisation}/`): Opt-in, imported only by hosts that need them. Each module is self-contained — it defines its own sops secrets, systemd services, and package requirements. Examples: `nvidia.nix`, `amd.nix`, `zfs-autounlock`, `kvm/gpu-passthrough`.

**Tier 4 — Per-host** (`hosts/{hostName}/configuration.nix`): Imports the applicable tiers and adds host-specific values: networking, ZFS pool names, service parameters, hardware UUIDs, tmpfiles rules.

Home Manager mirrors this: `users/alc/common.nix` → `users/alc/linux/common.nix` → optional operator layer → `users/alc/linux/{xyz,nux,rpi0}.nix`.

## Alternatives Considered

- **Flat per-host configs (full duplication)** — Rejected. Does not scale; common changes (SSH keys, Nix settings) require editing every host file independently.
- **Single monolithic shared module** — Rejected. Forces all configuration onto all hosts; cannot express role or service opt-in without conditional logic sprawl.
- **NixOS module system with `enable` options throughout** — Considered but kept minimal. Service modules use `enable` options internally, but the tier structure provides coarse composition without forcing every feature to be an explicit option in a global config.

## Consequences

- Adding a new host requires only writing `hosts/{name}/configuration.nix` importing the appropriate tiers. No changes to shared modules needed.
- Service modules are independently composable — they make no assumptions about which other modules are present.
- The full config of any host requires following imports across tiers; it is not visible from a single file.
- When adding configuration: all-host values → `common/default.nix`; role values → appropriate role module; service/hardware → new or existing service module; host-specific → `hosts/{name}/configuration.nix`. Never add per-host values to shared modules.

## September 2026 role review

[Issue #280](https://git.alc.xyz/alcxyz/nix-config/issues/280) separates the shared
desktop role from its current consumer's display identity. The public opt-in
`hardware.displayDeviceGuard` interface owns alias creation and verification;
private host policy supplies hardware values, driver selection, and GPU runtime
settings. Existing host imports remain explicit.

The common-policy review evaluated all ten exported NixOS configurations.
PipeWire and Bluetooth remain the accepted common baseline across workstation,
server, family-gaming, and embedded roles. Docker remains enabled on the six
non-embedded hosts and explicitly disabled on the four embedded hosts. Those
existing choices are retained: moving display policy does not establish a reason
to remove common audio, Bluetooth, or container capabilities. Any later narrowing
needs a capability-specific review of consumers and runtime requirements.
