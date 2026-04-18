# ADR-0012: Remote development via headless Wayland session instead of a VM

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `hosts/nux/configuration.nix`, `remote-dev` flake

## Context

We needed a persistent, remotely-accessible development environment on nux (home server) that provides:

- A graphical code editor (t3code) with SSO/OAuth support
- A terminal-first workflow (foot + tmux + nvim) alongside the GUI editor
- Access from all machines via SSH (terminal), RustDesk (native desktop), and noVNC (browser)
- A distributable artifact for non-NixOS users (Docker image, qcow2, ISO)

The initial approach considered was an Arch Linux VM (to leverage AUR for t3code), or a NixOS VM. Both carry significant overhead on a server that should dedicate its resources to the applications inside the environment, not the environment itself.

## Decision

Run a **headless sway (Wayland) session as a systemd service** directly on nux — no VM. The session is captured by wayvnc and exposed via noVNC (browser) and RustDesk (native remote desktop). SSH access provides terminal-only workflow to the same home directory and tmux sessions.

The environment is packaged as a **standalone Nix flake** (`remote-dev`) that outputs:

1. `nixosModules.default` — for NixOS users (zero overhead, just services)
2. `packages.*.qcow` / `iso` / `docker` — pre-built images via nixos-generators for everyone else

This avoids the Arch Linux / AUR dependency entirely since t3code is already packaged in `nix-packages`.

## Alternatives Considered

**Arch Linux VM (QEMU/KVM)**
Rejected. Adds 300MB+ RAM overhead (second kernel + init), 1-2GB disk for the base image, and CPU overhead from virtualisation. Also introduces imperative package management (pacman/AUR) into an otherwise fully declarative infrastructure. The sole advantage (AUR access for t3code) is already covered by `nix-packages`.

**NixOS VM (QEMU/KVM)**
Rejected for the same resource overhead as above. A NixOS VM would be declarative but still pays the VM tax (second kernel, second Nix store on disk). The Nix store duplication alone adds 3-5GB.

**X11 (Xvfb + x11vnc) instead of Wayland**
Considered for broader compatibility (especially with RustDesk). Rejected because foot is Wayland-only, and the user's workflow is already Wayland-native (Hyprland on xyz). If RustDesk Wayland support proves insufficient, this can be revisited.

**NixOS container (systemd-nspawn)**
Would provide namespace isolation with minimal overhead (~30-50MB RAM). Not chosen because the isolation isn't needed for a single-user home server, and it adds complexity to the systemd service graph. Could be added later if multi-tenant use emerges.

## Consequences

**Easier:**
- Near-zero resource overhead — all RAM/CPU goes to the actual dev tools
- Three access tiers (SSH, RustDesk, noVNC) to the same environment, same home dir
- Fully declarative — `nixos-rebuild switch` sets up the entire environment
- The flake produces images for non-NixOS users without any extra tooling

**Harder:**
- Headless sway requires careful systemd service ordering and a shared runtime directory (`/run/remote-dev`) for the Wayland socket
- Software rendering (pixman) since nux has no GPU — may be sluggish for heavy UI workloads
- RustDesk's Wayland support is less mature than X11; may need workarounds

**Trade-offs:**
- No isolation between the dev environment and the host — acceptable for a single-user server
- The `remote-dev` flake depends on `nixos-generators` which is deprecated in favor of built-in nixpkgs 25.05 image generation; migration needed eventually
