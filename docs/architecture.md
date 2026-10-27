# Architecture diagrams

Overview diagrams of this flake, in Mermaid so Forgejo and GitHub render them
inline. They summarise the code and the linked decisions. If a diagram and the
code disagree, the code wins, so update the diagram along with any change it
depicts. Private material (endpoints, secret wiring, builder selection,
runbooks) stays in `nix-secrets` and is shown here only as an opaque box.

1. [Fleet](#fleet)
2. [Flake composition](#flake-composition)
3. [Configuration layering](#configuration-layering)
4. [From change to deployment](#from-change-to-deployment)
5. [Fleet deploy order](#fleet-deploy-order)
6. [Maintained project refresh](#maintained-project-refresh)

## Fleet

Hosts and their inventory roles, from [`inventory.nix`](../inventory.nix).
The three cluster members are all embedded-etcd k3s servers that also run
workloads ([ADR-0017](adr/0017-k3s-cluster-topology.md)). The two DNS Pis
resolve names for the whole network outside the cluster, so they are never
down together.

```mermaid
flowchart LR
  subgraph operators["Operator machines (source workspace)"]
    xyz["xyz<br/>workstation<br/>x86_64-linux"]
    mac["mac<br/>mac<br/>aarch64-darwin"]
  end

  subgraph cluster["k3s cluster: 3 servers, schedulable"]
    nux["nux<br/>nuc"]
    nex["nex<br/>nuc"]
    xev["xev<br/>k8s-worker"]
  end

  subgraph tv["TV clients: tv-client, aarch64-linux"]
    subgraph dns["Network DNS pair"]
      rpi0["rpi0"]
      rpi1["rpi1"]
    end
    rpi2["rpi2"]
    rpi3["rpi3"]
  end

  subgraph couch["Other clients"]
    xps["xps<br/>laptop-workstation<br/>docked media center"]
    madsil["madsil<br/>family-gaming<br/>managed remotely"]
  end

  xyz -->|"deploy, nixfleet"| cluster
  xyz -->|"deploy, nixfleet"| tv
  xyz -->|"deploy, nixfleet"| couch
  mac -.->|"emergency operator"| cluster
```

Servers and Pis hold no repository clones: every change is made on `xyz` or
the Mac and switched remotely. `xps` and the TV clients are controller-first
Moonlight clients ([nixbox client guide](nixbox-client.md),
[gaming map](gaming/README.md)).

## Flake composition

How [`flake.nix`](../flake.nix) turns inputs and the inventory into outputs
through the [flake-parts](https://flake.parts) modules in [`flake/`](../flake).
Every host output is built from the same per-system package set and the same
inventory-derived `specialArgs`.

```mermaid
flowchart LR
  subgraph inputs["Inputs, pinned in flake.lock"]
    nixpkgs["nixpkgs<br/>nixos-unstable"]
    np["nix-packages<br/>public packages"]
    apps["Maintained tools and apps<br/>release and dev builds"]
    upstream["home-manager, nix-darwin,<br/>sops-nix, nixos-hardware, ..."]
    secrets["nix-secrets<br/>private modules"]
  end

  inv["inventory.nix<br/>hosts, roles, k8s roles"]

  subgraph flake["flake/"]
    pkgs["pkgs.nix<br/>overlays per system"]
    core["core.nix<br/>alc.inventory, alc.pkgsFor"]
    lib["hosts/lib.nix<br/>specialArgs per host"]
    nixos["hosts/nixos.nix"]
    darwin["hosts/darwin.nix"]
    hm["hosts/home-manager.nix"]
    per["per-system.nix<br/>dev shell, packages, checks"]
  end

  hostcfg["hosts/HOST/<br/>configuration.nix"]
  usercfg["users/alc/linux/HOST.nix<br/>users/alc/darwin/mac.nix"]

  subgraph outputs["Outputs"]
    oN["nixosConfigurations.HOST"]
    oD["darwinConfigurations.mac<br/>and aliases"]
    oH["homeConfigurations.alc-HOST"]
    oC["checks, packages, devShells"]
  end

  nixpkgs --> pkgs
  np -->|"filtered overlay"| pkgs
  apps --> pkgs
  pkgs --> core
  inv --> core
  core --> lib
  lib --> nixos
  lib --> darwin
  lib --> hm
  upstream --> nixos
  upstream --> darwin
  upstream --> hm
  secrets -->|"private defaults<br/>and policy"| nixos
  hostcfg --> nixos
  hostcfg --> darwin
  usercfg --> hm
  core --> per
  nixos --> oN
  darwin --> oD
  hm --> oH
  per --> oC
```

The NixOS builder also asserts that k3s is enabled exactly on the hosts the
inventory gives a `k8sRole`. See
[ADR-0007](adr/0007-filtered-nix-packages-overlay.md) for the filtered package
overlay and [ADR-0002](adr/0002-nix-secrets-separate-repository.md) for the
private repository boundary.

## Configuration layering

Each host composes its NixOS system from four tiers
([ADR-0006](adr/0006-four-tier-module-layering.md)), and its Home Manager
profile from a matching user chain. Both read host facts from one typed
projection of the inventory, `alc.host`, instead of branching on host names.

```mermaid
flowchart TB
  inv["inventory.nix"] -->|"projected by<br/>modules/shared/host-metadata.nix"| meta["alc.host<br/>name, role, aliases, k8s"]
  pkgsets["modules/shared/pkgsets.nix<br/>package sets by role"]

  subgraph system["NixOS system"]
    host["Tier 4: hosts/HOST/configuration.nix"]
    t1["Tier 1: modules/nixos/common/default.nix<br/>every host"]
    t2["Tier 2, where used: common/desktop.nix (xyz)<br/>or common/server.nix (servers, Pis)"]
    prof["profiles/nixbox-*<br/>couch and TV clients"]
    t3["Tier 3: services/, hardware/,<br/>virtualisation/, security/"]
    sysPriv["nix-secrets NixOS modules"]
    host --> t1
    host --> t2
    host --> prof
    host --> t3
    host --> sysPriv
    prof --> t3
  end

  subgraph home["Home Manager, user alc"]
    hHost["users/alc/linux/HOST.nix"]
    op["linux/operator.nix<br/>xyz, xps, nux, nex, xev"]
    emb["linux/embedded.nix<br/>rpi0 to rpi3"]
    lcommon["linux/common.nix"]
    common["users/alc/common.nix<br/>all platforms"]
    macHM["users/alc/darwin/mac.nix"]
    hmMods["modules/home-manager/<br/>programs, services, workspace"]
    hmPriv["nix-secrets and work flake<br/>Home Manager modules"]
    hHost --> op
    hHost --> emb
    op -->|"through the private<br/>operator module"| lcommon
    lcommon --> common
    macHM --> common
    hHost --> hmMods
    macHM --> hmMods
    op --> hmPriv
    macHM --> hmPriv
  end

  meta -.-> system
  meta -.-> home
  pkgsets -.-> system
  pkgsets -.-> home
```

`xps` and `madsil` import no Tier 2 layer: the XPS composes the Nixbox
session profile and madsil its gaming services directly. `madsil` also embeds
Home Manager for the family user from [`users/madsil/`](../users/madsil) in its
NixOS configuration, alongside the standalone `alc-madsil` profile from
`users/alc/linux/madsil.nix`. The inventory role picks
each host's package sets, so host files write
`pkgsets.home.${hostRole.homePackageSet}` rather than naming a role
([ADR-0008](adr/0008-pkgsets-centralised-package-management.md)).

## From change to deployment

The path a change takes from a branch to the hosts. Pull requests into `dev`
run only credential-free checks; the full evaluation of every exported system
runs in a scheduled, trusted local job, and its commit status is the receipt
the promotion to `main` requires ([validation](validation.md),
[ADR-0067](adr/0067-explicit-consumer-and-platform-validation.md),
[ADR-0098](adr/0098-date-tagged-promotions.md)).

```mermaid
flowchart TD
  edit["Change on a topic branch<br/>(on xyz or the Mac)"]
  local["Local checks<br/>just check, affected configurations"]
  prDev["Pull request into dev"]
  light["Hosted CI on forgejo-podman-canary<br/>format, shell lint, hygiene, credential-free tests"]
  review["pr-review"]
  dev[("dev")]
  full["Scheduled local validation<br/>scripts/ci/check-configurations.sh<br/>native checks, then all systems"]
  receipt["Commit status ci/local-configurations<br/>on the dev head"]
  prMain["Pull request dev into main"]
  gate["Hosted CI accepts only the exact<br/>dev head with a passing receipt"]
  main[("main")]
  tag["Annotated date tag vYYYY.MM.DD<br/>and Forgejo release"]
  deploy["deploy --all from xyz,<br/>or deploy HOST"]

  edit --> local --> prDev
  prDev --> light --> review -->|"fast-forward merge"| dev
  dev --> full --> receipt
  dev --> prMain --> gate
  receipt -.-> gate
  gate -->|"fast-forward merge"| main --> tag
  dev --> deploy
```

Hosts are deployed from the operator's checkout, normally `dev`; the
promotion records a validated, tagged state of it. `deploy` warns when the
lock does not point at the validated `nix-packages` revision
([ADR-0080](adr/0080-promoted-package-ref.md)).

## Fleet deploy order

What `deploy --all` does, as configured by
[`packages/nix-deploy`](../packages/nix-deploy/default.nix) from the
inventory. Only changed configurations are switched, and hosts with
`deployAll = false` (`madsil`, `rpi2`, `rpi3`) are left out unless named.
Home Manager profiles switch too; the serial groups govern system switches.

```mermaid
flowchart TD
  start["deploy --all on xyz"]
  lock["Check flake.lock against the<br/>promoted nix-packages revision (warn only)"]
  pre["Preflight: SSH reachability<br/>(unreachable hosts skipped unless --fail-unreachable)"]
  build["Build changed system and<br/>Home Manager configurations"]
  parallel["Switch ungrouped hosts<br/>xyz, xps"]
  subgraph k3s["Serial group: k3s servers, one at a time"]
    direction LR
    k1["nex"] -->|"gate"| k2["nux"] -->|"gate"| k3["xev"]
  end
  kgate["Gate: before a switch, the other members' API servers<br/>are ready and their nodes Ready; after it,<br/>the switched host must pass the same check"]
  subgraph dnsg["Serial group: DNS servers, one at a time"]
    direction LR
    d1["rpi0"] -->|"gate"| d2["rpi1"]
  end
  dgate["Gate: before a switch, the other Pi answers pi.hole<br/>and resolves a fresh public name; after it,<br/>the switched Pi must pass the same check"]

  start --> lock --> pre --> build --> parallel
  parallel --> k3s --> dnsg
  kgate -.- k3s
  dgate -.- dnsg
```

Every member must pass its check before the group starts. A failed check
stops the group and leaves its remaining members untouched, so `deploy` switches
at most one etcd member or resolver at a time and only while the others answer
their checks. It cannot protect against a member failing for other reasons
during the switch. Node
reboots are separate (`kreboot`, `koff`, `kon`); `nixfleet status` only reads
state.

## Maintained project refresh

How the owner's tools and apps reach the hosts
([README](../README.md#maintained-projects),
[ADR-0086](adr/0086-released-tool-inputs.md),
[ADR-0087](adr/0087-side-by-side-dev-tools.md),
[ADR-0089](adr/0089-released-and-dev-app-inputs.md)). The commands only move
pins in `flake.lock`; a rebuild never moves an input to a newer branch head.

```mermaid
flowchart LR
  subgraph repos["Project repositories"]
    relMain["main branches<br/>released builds"]
    relDev["dev branches<br/>dev builds"]
  end

  tools["tools-update<br/>apps-update"]
  devtools["dev-tools-update<br/>dev-apps-update<br/>dms-update"]
  lockf[("flake.lock")]
  inspect["Inspect lock diff"]
  switch["Switch Home Manager<br/>or the system"]
  out["Release under its own name,<br/>dev build next to it as NAME-dev"]

  relMain --> tools --> lockf
  relDev --> devtools --> lockf
  lockf --> inspect --> switch --> out
```

Projects without releases yet, and apps that cannot run twice on one host,
follow `dev` under their own name instead of getting a `-dev` twin.
