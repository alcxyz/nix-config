# ADR-0026: Unified source directory layout across machines

**Status:** Accepted (implemented on xyz)
**Date:** 2026-04-27
**Applies to:** all hosts (xyz, nux, mac), `home-manager`, `gitops`

## Context

Development repositories are currently spread across multiple locations with no consistent convention:

- `~/gitops/` — infrastructure (k8s, Docker), application source (submodules), and tooling all coexist
- `~/git/` — some standalone repos
- `~/dev/git/alcxyz/` — more repos
- `~/nix/` — nix-config, nix-packages, nix-secrets

The gitops submodule pattern is a legacy of the Docker Compose era, where `docker compose build` needed source directories adjacent to compose files. Post k8s migration, this coupling no longer exists:

- Kubernetes pulls container images — it doesn't need source trees
- CI (Forgejo Actions) builds images from standalone repos
- Tools like paperless-tools and leantime-tidy are consumed as Nix flake inputs, not local paths
- The submodules add clone complexity and `.gitmodules` maintenance for no operational benefit

This ADR proposes a unified directory layout applied consistently across all machines.

## Decision

Adopt a single `~/src/` root with purpose-based subdirectories:

```
~/src/
├── infra/                    # Infrastructure-as-code
│   ├── gitops/               # k8s manifests, Docker compose, Flux, docs
│   ├── nix-config/           # NixOS / nix-darwin / home-manager
│   ├── nix-packages/         # Custom Nix packages and flake
│   └── nix-secrets/          # SOPS-encrypted secrets repo
│
├── apps/                     # Application source repos (deployed services)
│   ├── telegram-bot/
│   ├── leantime-bot/
│   ├── nssupply/
│   ├── kjekkmann/
│   ├── beautyzone/
│   └── ...
│
├── platform/                 # Platform modules and client-facing platform state
│   ├── client-records/
│   ├── nexus/
│   ├── timebank/
│   ├── regnskap/
│   ├── digipost-sign/
│   └── ...
│
├── tools/                    # CLI utilities and developer tooling
│   ├── paperless-tools/
│   └── ...
│
├── orgs/                     # Repos owned by other GitHub/Forgejo orgs
│   ├── alcorg/               # alcorg org repos
│   └── bn-apps/              # bn-apps work org repos
│
├── forks/                    # Upstream forks (intent to contribute back)
│   └── ...
│
├── clones/                   # Reference clones (read-only, no upstream PR intent)
│   ├── JimsGarage/
│   └── ...
│
├── sites/                    # Static sites and web projects
│   └── ...
│
├── personal/                 # Personal repos (journal, profile, etc.)
│   └── ...
│
└── lib/                      # Libraries, shared packages, experiments
    └── ...
```

### Key principles

1. **Every repo is a standalone clone** — no submodules. The connection between source and deployment is the container registry, not a filesystem path.
2. **Purpose-based grouping** — infra, platform, apps, tools, lib. Not grouped by language, org, or host.
3. **Consistent across all machines** — the same `~/src/` layout on xyz, nux, and mac. Not every machine needs every repo, but the paths are always the same.
4. **gitops becomes pure infrastructure** — remove all submodules, keep only `k8s/`, `docker/`, `docs/`, and `tools/` (for infra-specific tools like leantime-tidy that live in the gitops repo).

### gitops cleanup

Remove submodules from gitops:
- `nssupply`, `telegram-bot`, `leantime-bot` → cloned under `~/src/apps/`
- `timebank`, `regnskap`, `digipost-sign`, `nexus`, `client-records` → cloned under `~/src/platform/`
- `paperless-tools` → cloned under `~/src/tools/`
- `beautyzone`, `kjekkmann` → cloned under `~/src/apps/`

The `tools/` directory inside gitops (tunnel) stays — these are infrastructure tools tightly coupled to gitops, not standalone repos. leantime-tidy has since been extracted to `~/src/tools/leantime-tidy/` (gitops ADR-011).

### Migration path

1. Create `~/src/{infra,apps,tools,lib}/` via home-manager
2. Clone repos into their new locations
3. Remove submodules from gitops (update `.gitmodules`, `git rm` submodule dirs)
4. Update references in CLAUDE.md, shell aliases, direnv configs, systemd services, and ADR docs
5. Move `~/nix/*` to `~/src/infra/` (update flake self-references if needed)
6. Symlink or remove `~/gitops`, `~/git`, `~/dev/git` after transition period
7. Apply same layout on each machine as repos are needed

## Alternatives Considered

**Keep submodules, just reorganize within gitops** — rejected because the submodule pattern itself is the problem. It adds complexity (sync, init, update) without serving a purpose post-k8s.

**`~/repos/` or `~/code/` as root** — `~/src/` is shorter, conventional, and unambiguous. Any of these would work; `src` was chosen for brevity.

**Group by org/owner (e.g., `~/src/alcxyz/`, `~/src/client/`)** — rejected because you're the primary owner of almost everything. Owner-based grouping would create a single dominant folder with the same flat problem. Purpose-based grouping scales better.

**Keep nix repos separate (`~/nix/`)** — rejected for consistency. Nix repos are infrastructure; `~/src/infra/` is their natural home. A symlink `~/nix → ~/src/infra` can ease the transition.

## Consequences

- **All absolute paths in CLAUDE.md, ADRs, scripts, and configs change** — this is the biggest migration cost. A transition period with symlinks reduces breakage.
- **No more `git submodule` commands** — simpler clones, no sync/init/update dance.
- **Muscle memory adjustment** — `cd ~/gitops` becomes `cd ~/src/infra/gitops`. Shell aliases and `z`/`zoxide` will smooth this over quickly.
- **New machines are self-documenting** — the directory structure itself communicates where things go, reducing setup confusion.
- **home-manager can enforce the layout** — create the directories declaratively, set session variables for common paths.
