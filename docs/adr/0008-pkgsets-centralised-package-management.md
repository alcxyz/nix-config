# ADR-0008: Centralised package sets via pkgsets.nix

**Status:** Accepted
**Date:** 2026-04-18
**Amended:** 2026-10-28
**History:** [replaced text](archive/0008-pkgsets-centralised-package-management-history.md)
**Applies to:** `modules/shared/pkgsets.nix`

## Context

Without a centralised approach, package lists scatter across host configs and role modules, leading to duplication and drift: the same package added to three hosts independently, removed from one but not the others, or a role-level package ending up in a per-host file. Role-based thinking ("a desktop host gets these packages, a server gets those") needs a single canonical definition that role modules can reference.

## Decision

All package sets are defined in `modules/shared/pkgsets.nix`, exported as a structured attribute set consumed by role modules and per-host configs. `modules/nixos/common/pkgsets.nix` only re-imports it for older import paths.

- `sys.base` / `sys.linux` / `sys.linuxEmbedded` / `sys.linuxWorkstation` / `sys.linuxDesktop`: system-level package sets by scope
- `hm.base` / `hm.linux` / `hm.embedded` / `hm.cloud` / `hm.mac` / `hm.dev` / `hm.iac` / `hm.k8s` / `hm.gaming` / `hm.ai` / `hm.desktop*` / `hm.linuxExtras` / `hm.workstationExtras`: Home Manager sets by scope
- `system.workstation` / `system.server` / `system.embedded` / `system.mac`: composed system presets for role modules
- `home.workstation` / `home.nuc` / `home.server` / `home.embedded` / `home.family-gaming` / `home.mac`: composed HM presets by host class

Each `inventory.nix` role names its presets through `homePackageSet` and `systemPackageSet` ([ADR-0036](0036-host-inventory-source-of-truth.md)). Current host class mapping (home preset, system preset):

- `workstation`: xyz and xps (full desktop, dev, gaming); system `workstation`
- `nuc`: nux and nex (base + linux + k8s); system `server`
- `server`: xev (base + linux + k8s + dev + iac); system `server`
- `family-gaming`: madsil's role (base + linux + desktop + gaming); system `workstation`. madsil's Home Manager file does not use this preset yet and lists its few packages inline.
- `embedded`: rpi0 to rpi3 (the small appliance operator baseline); system `embedded`
- `mac`: mac laptop (base + cloud + mac + dev + iac + k8s + ai); system `mac`

Modules import pkgsets.nix with `pkgs` and `inputs` in scope and select the preset of their host's role:
```nix
let pkgsets = import "${configDir}/modules/shared/pkgsets.nix" { inherit pkgs inputs; };
in { environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet}; }
```

## Alternatives Considered

- **Packages declared inline per role module**: Rejected. Role modules would own package lists that belong to multiple modules; cross-cutting changes (adding a dev tool to all desktop hosts) require editing multiple files.
- **Packages declared per host**: Rejected. Maximum duplication; no shared semantics between hosts with the same role.
- **NixOS `environment.systemPackages` lists in a shared option**: Considered but rejected in favour of explicit import. The explicit import pattern keeps pkgsets.nix as a pure data file with no NixOS module machinery, making it easy to read and audit.

## Consequences

- Package additions/removals for a role are made in one place and immediately apply to all hosts importing that role.
- `pkgsets.nix` is a high-blast-radius file: incorrect edits affect all hosts simultaneously.
- Packages from external flakes (for example `zen-browser` from nix-packages, [ADR-0014](0014-self-package-zen-browser.md)) reach `pkgsets.nix` as `pkgs.<name>` through the filtered overlay ([ADR-0007](0007-filtered-nix-packages-overlay.md)). `pkgsets.nix` still accepts an optional `inputs` argument.
- Per-host one-off packages are the exception and belong in `hosts/{name}/configuration.nix`, not in pkgsets.nix. When adding a package that should apply to a role, add it to the appropriate set in pkgsets.nix rather than inline in any module or host file.
