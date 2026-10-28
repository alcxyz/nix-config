# ADR-0006: Four-tier module layering (common → role → service/hardware → per-host)

**Status:** Accepted
**Date:** 2026-04-18
**Amended:** 2026-10-28
**History:** [replaced text](archive/0006-four-tier-module-layering-history.md)
**Applies to:** `modules/nixos/`, `hosts/`, `users/`

## Context

This repo manages ten NixOS hosts and one nix-darwin Mac across three
architectures (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`), listed in
`inventory.nix`. They share significant configuration (users, SSH keys, Nix
settings, audio, Bluetooth) but diverge in role and hardware. Without
structure, configuration either duplicates across hosts or becomes one tangled
monolithic module that opts everything in everywhere.

## Decision

Configuration is organised into four tiers, composed via explicit `imports` in each host's `configuration.nix`:

**Tier 1: Common base** (`modules/nixos/common/default.nix`): Applied to every NixOS host. Nix daemon settings, binary caches, private SSH policy integration, user/group definitions, core services (openssh, pipewire, bluetooth, Docker), fonts, locale, keyboard, bootloader. The flake's NixOS host builder (`flake/hosts/nixos.nix`) adds the sops-nix module and the private default modules to every NixOS host.

**Tier 2: Role** (`modules/nixos/common/{desktop,server}.nix`): Applied by host function. `desktop.nix` adds Hyprland, the display manager, Docker defaults, kanata, and desktop packages. GPU driver selection, display identity, and GPU container policy are supplied by explicit host hardware/private modules. `server.nix` adds server packages and server defaults. Optional capabilities such as distributed-build client credentials live in separate explicit modules.

The shared desktop role carries no display identity of its consumers. The public opt-in `hardware.displayDeviceGuard` interface (`modules/nixos/hardware/display-device-guard.nix`) owns alias creation and verification; private host policy supplies hardware values, driver selection, and GPU runtime settings ([issue #280](https://git.alc.xyz/alcxyz/nix-config/issues/280)).

**Tier 3: Service and hardware modules** (`modules/nixos/{services,hardware,virtualisation}/`): Opt-in, imported only by hosts that need them. Each module is self-contained: it defines its own sops secrets, systemd services, and package requirements. Examples: `nvidia.nix`, `amd.nix`, `display-device-guard.nix`, `kvm/gpu-passthrough`.

**Tier 4: Per-host** (`hosts/{hostName}/configuration.nix`): Imports the applicable tiers and adds host-specific values: networking, ZFS pool names, service parameters, hardware UUIDs, tmpfiles rules.

A host may split its tier-4 values into explicit host-local modules. The xyz storage tier is `hosts/xyz/storage.nix`: generic ZFS package coupling, storage helper assembly, filesystem declarations, and systemd ordering remain public, and a typed `xyz.storage.policy` option supplies the host values required to render those mechanisms. The named private storage module owns the values and sensitive standard-option assignments. This keeps the tier-4 import visible without publishing host storage topology or operational policy.

Home Manager mirrors this: `users/alc/common.nix` → `users/alc/linux/common.nix` → optional operator layer → `users/alc/linux/{hostName}.nix`. Operator hosts import `users/alc/linux/operator.nix`, which brings in both common layers. The embedded hosts use the compact `users/alc/linux/embedded.nix` profile instead, madsil's standalone `users/alc/linux/madsil.nix` imports nothing and lists its packages inline, and the Mac uses `users/alc/darwin/mac.nix` on top of `users/alc/common.nix`.

### Common baseline

PipeWire and Bluetooth remain the accepted common baseline across workstation,
server, family-gaming, and embedded roles. Docker is enabled on the six
non-embedded NixOS hosts and explicitly disabled on the four embedded hosts.
Moving display policy did not establish a reason to remove common audio,
Bluetooth, or container capabilities. Any narrowing needs a capability-specific
review of consumers and runtime requirements.

## Alternatives Considered

- **Flat per-host configs (full duplication)**: Rejected. Does not scale; common changes (SSH keys, Nix settings) require editing every host file independently.
- **Single monolithic shared module**: Rejected. Forces all configuration onto all hosts; cannot express role or service opt-in without conditional logic sprawl.
- **NixOS module system with `enable` options throughout**: Considered but kept minimal. Service modules use `enable` options internally, but the tier structure provides coarse composition without forcing every feature to be an explicit option in a global config.

## Consequences

- Adding a new NixOS host requires its `inventory.nix` entry ([ADR-0036](0036-host-inventory-source-of-truth.md)), `hosts/{name}/configuration.nix` importing the appropriate tiers, and its Home Manager host file. No changes to shared modules needed.
- Service modules are independently composable: they make no assumptions about which other modules are present.
- The full config of any host requires following imports across tiers; it is not visible from a single file.
- When adding configuration: all-host values → `common/default.nix`; role values → appropriate role module; service/hardware → new or existing service module; host-specific → `hosts/{name}/configuration.nix`. Never add per-host values to shared modules.
- Host imports remain explicit; host-specific hardware values reach shared roles only through a typed public interface backed by private host policy.
