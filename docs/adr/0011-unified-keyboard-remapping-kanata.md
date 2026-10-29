# ADR-0011: Keyboard remapping with one shared kanata config on Linux and Karabiner on macOS

**Status:** Accepted
**Date:** 2026-04-18
**Amended:** 2026-10-29
**History:** [replaced text](archive/0011-unified-keyboard-remapping-kanata-history.md)
**Applies to:** `users/alc/configs/kanata/kanata.kbd`, `modules/nixos/common/desktop.nix`, `hosts/xyz/configuration.nix`, `users/alc/configs/karabiner/karabiner.json`, `modules/home-manager/programs/karabiner/`, `hosts/mac/configuration.nix`

## Context

Three keyboards are in play:

1. **Glove80** (US layout, ZMK firmware): connected via Bluetooth to any machine.
2. **Mac built-in keyboard** (Norwegian layout, Mac modifier order): macOS only.
3. **Generic PC keyboard** (Norwegian layout, standard PC modifier order): connected to either Linux or Mac.

The Glove80 has its own ZMK firmware handling key layout, but kanata adds tap-hold behaviors, a navigation layer, and accented character support (éæøå) on top. Karabiner on macOS provides different but overlapping functionality: home row mods, caps+hjkl arrows, dual-function modifiers.

The goal is reproducibility: switch machines and have keyboard behavior ready without manual configuration.

## Decision

Linux hosts share one kanata config, `users/alc/configs/kanata/kanata.kbd`,
written for the Glove80 (US layout). It is owned by `xyz`: the mappings in use
there are the reference for every other host and tool.

`modules/nixos/common/desktop.nix` runs it as the single `services.kanata`
instance `main`, restarted after transient device failures. `xyz` is the only
host that imports that module, so it is the only host running kanata today.
Another Linux host that enables kanata uses the same file with its own device
allowlist. `xps` is the intended next host; it runs no kanata yet.

On Linux desktop hosts, the shared kanata instance excludes the synthetic
keyboards that streaming servers create (`Keyboard passthrough`, `waynergy
keyboard`), so they stay available to their own input stack instead of being
grabbed by Kanata.

On `xyz`, Kanata uses an explicit device-name allowlist supplied by the private
host input-hardware policy. Only the selected physical keyboard interfaces are
captured; composite receiver interfaces, mice, media controls, and Sunshine's
virtual passthrough devices bypass Kanata. This makes streamed input independent
of Kanata's device discovery and fails safely when an unknown keyboard is
connected: ordinary input remains available, but Kanata mappings require an
intentional declarative allowlist update.

On macOS, kanata does not run: Karabiner Elements handles keyboard remapping
instead. Its config is a hand-maintained
`users/alc/configs/karabiner/karabiner.json` that is to mirror `kanata.kbd`.
It does not yet. Differences include: held Caps Lock is Super in kanata but
Escape plus the navigation layer in Karabiner, held backtick is the navigation
layer in kanata but Option in Karabiner, only Karabiner has home row mods, and
the navigation layer's accented characters (å, ø) sit on different keys. Since
2026-04-20 (commit bca715a2) the Home Manager module
(`modules/home-manager/programs/karabiner/`) links the static file into place
instead of generating it. The link target is the flake source in the store
(`configDir`), so an edit applies after the next Home Manager switch. Kanata was abandoned on macOS because SentinelOne quarantines all
unsigned/ad-hoc-signed binaries: both the Nix store binary and the Homebrew
binary were killed. Karabiner is properly Apple-notarized and unaffected. It is
installed as the `karabiner-elements` Homebrew cask.

The earlier plan of three device-specific kanata configs (Glove80, Mac
built-in, generic Norwegian PC) with a multi-instance `services.kanata` was
given up (owner decision, 2026-10-29); its text is in the history file.

## Alternatives Considered

- **Three device-specific kanata configs with a multi-instance `services.kanata`**: given up (owner decision, 2026-10-29). One shared config is what runs, and the plan's text is in the history file.
- **Kanata on macOS**: abandoned because SentinelOne kills the kanata binaries (see Decision).
- **Use karabiner everywhere (via nix-darwin `services.karabiner-elements`)**: rejected because karabiner is macOS-only, so Linux would still need a separate tool.
- **Remap everything in Glove80 ZMK firmware**: rejected because ZMK only covers the Glove80 itself; the Mac built-in and generic keyboards still need OS-level remapping. Also, accented character support (éæøå) requires OS-level Unicode output.

## Consequences

- **Easier:** On Linux, one tool and one config file, declarative and reproducible. A Linux host that enables kanata gets the reference mappings after `nixos-rebuild`, once its keyboards are on its allowlist.
- **Trade-off:** Only the Glove80 has a kanata config written for it. A Linux host applies `kanata.kbd` to every keyboard on its allowlist, including Norwegian-layout ones.
- **Trade-off (macOS):** Uses Karabiner instead of kanata: two different tools with different config formats across Linux/macOS. `kanata.kbd` remains the canonical reference for desired mappings; the Karabiner JSON is maintained by hand to mirror it, and the differences noted in the Decision remain until it is brought in line. SentinelOne kills all kanata binaries (nix, brew) on sight, making Karabiner the only viable option on managed macOS machines.
- **Trade-off (streaming hosts):** A newly added physical keyboard does not receive Kanata mappings until its stable device name is added declaratively.
