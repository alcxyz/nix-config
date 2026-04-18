# ADR-0011: Unified keyboard remapping via kanata across all hosts and keyboards

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `users/alc/configs/kanata/`, `modules/nixos/common/desktop.nix`, `hosts/mac/configuration.nix`

## Context

Keyboard remapping is currently split across two tools and configured inconsistently:

- **Linux (NixOS):** kanata via `services.kanata`, with a single `.kbd` config for the Glove80 (US layout). Declarative and nix-managed.
- **macOS:** Karabiner Elements configured through its GUI. Not declarative, not reproducible, not in the nix-config repo.

Three keyboards are in play:

1. **Glove80** (US layout, ZMK firmware) — connected via Bluetooth to any machine.
2. **Mac built-in keyboard** (Norwegian layout, Mac modifier order) — macOS only.
3. **Generic PC keyboard** (Norwegian layout, standard PC modifier order) — connected to either Linux or Mac.

The Glove80 has its own ZMK firmware handling key layout, but kanata adds tap-hold behaviors, a navigation layer, and accented character support (éæøå) on top. The karabiner config provides different but overlapping functionality: home row mods, caps+hjkl arrows, dual-function modifiers.

The goal is full reproducibility — switch machines and have keyboard behavior ready without manual configuration.

## Decision

Consolidate all keyboard remapping onto kanata with three device-specific configs managed in the nix-config repo:

1. **`kanata-glove80.kbd`** — for the Glove80 (US layout). Used on both Linux and macOS. Based on the current working Linux kanata config.
2. **`kanata-mac-builtin.kbd`** — for the Mac built-in keyboard (Norwegian, Mac modifier layout). Ported from the current karabiner config.
3. **`kanata-generic-no.kbd`** — for generic PC Norwegian keyboards. Based on the mac-builtin config with adjusted modifier positions for standard PC layout.

Device filtering directs each keyboard to its config:
- **Linux:** `linux-dev` in `defcfg` to route Glove80 and generic Norwegian keyboards to their respective configs.
- **macOS:** `macos-dev-names-include` in `defcfg` to route Glove80, Mac built-in, and generic keyboards.

On macOS, kanata runs via launchd services (nix-darwin or home-manager managed). On Linux, the existing `services.kanata` is extended to support multiple keyboard instances.

Karabiner Elements is removed. Only the Karabiner-DriverKit-VirtualHIDDevice driver is retained, as kanata requires it on macOS for key interception.

## Alternatives Considered

- **Keep karabiner on macOS, kanata on Linux** — rejected because it means maintaining two tools with different config formats for overlapping functionality, and the karabiner config is not declarative/reproducible.
- **Use karabiner everywhere (via nix-darwin `services.karabiner-elements`)** — rejected because karabiner is macOS-only, so Linux would still need a separate tool.
- **Remap everything in Glove80 ZMK firmware** — rejected because ZMK only covers the Glove80 itself; the Mac built-in and generic keyboards still need OS-level remapping. Also, accented character support (éæøå) requires OS-level Unicode output.

## Consequences

- **Easier:** One tool, one config format, fully declarative and reproducible across machines. Adding a new machine means the keyboard behavior is ready after `nixos-rebuild` or `darwin-rebuild`.
- **Easier:** Sharing ideas between keyboard configs (e.g. porting home row mods to the Glove80 or nav layer to Norwegian keyboards) is trivial since they share the same format.
- **Harder:** macOS kanata depends on the Karabiner virtual HID driver, which must be installed separately (not available in nixpkgs). This is a manual bootstrap step.
- **Trade-off:** The generic Norwegian config is based on the Mac built-in config rather than being designed independently. Minor differences in physical layout between Mac and PC keyboards may surface edge cases that need adjustment.
