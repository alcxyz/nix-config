# ADR-0008: Centralised package sets via pkgsets.nix

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/common/pkgsets.nix`

## Context

Without a centralised approach, package lists scatter across host configs and role modules, leading to duplication and drift: the same package added to three hosts independently, removed from one but not the others, or a role-level package ending up in a per-host file. Role-based thinking ("a desktop host gets these packages, a server gets those") needs a single canonical definition that role modules can reference.

## Decision

All package sets are defined in `modules/nixos/common/pkgsets.nix`, exported as a structured attribute set consumed by role modules and per-host configs:

- `sys.base` / `sys.linux` / `sys.linuxDesktop` — system-level package sets by role
- `hm.base` / `hm.linux` / `hm.dev` / `hm.iac` / `hm.k8s` / `hm.gaming` / `hm.ai` / `hm.desktop*` / `hm.workstation*` — Home Manager sets by scope
- `system.workstation` / `system.server` / `system.mac` — composed system presets for role modules
- `home.workstation` / `home.nuc` / `home.server` / `home.embedded` / `home.mac` — composed HM presets by host class

Host class mapping:
- `workstation` — xyz (full desktop, dev, gaming)
- `nuc` — nux and future NUCs (base + linux + k8s)
- `server` — future dedicated server (base + linux + k8s + dev + iac)
- `embedded` — rpi0 and similar SBCs (base + linux, minimal)
- `mac` — mac laptop (base + cloud + mac + dev + iac + k8s + ai)

Modules import pkgsets.nix with `pkgs` and `inputs` in scope:
```nix
let pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" { inherit pkgs inputs; };
in { environment.systemPackages = pkgsets.system.desktop; }
```

## Alternatives Considered

- **Packages declared inline per role module** — Rejected. Role modules would own package lists that belong to multiple modules; cross-cutting changes (adding a dev tool to all desktop hosts) require editing multiple files.
- **Packages declared per host** — Rejected. Maximum duplication; no shared semantics between hosts with the same role.
- **NixOS `environment.systemPackages` lists in a shared option** — Considered but rejected in favour of explicit import. The explicit import pattern keeps pkgsets.nix as a pure data file with no NixOS module machinery, making it easy to read and audit.

## Consequences

- Package additions/removals for a role are made in one place and immediately apply to all hosts importing that role.
- `pkgsets.nix` is a high-blast-radius file — incorrect edits affect all hosts simultaneously.
- `pkgsets.nix` receives `inputs` as an argument to conditionally include packages from external inputs (e.g. zen-browser from nix-packages) with availability guards.
- Per-host one-off packages are the exception and belong in `hosts/{name}/configuration.nix`, not in pkgsets.nix. When adding a package that should apply to a role, add it to the appropriate set in pkgsets.nix rather than inline in any module or host file.
