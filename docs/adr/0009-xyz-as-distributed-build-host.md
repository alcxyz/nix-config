# ADR-0009: xev, xyz, and mac distributed build posture

**Status:** Accepted (amended 2026-05-14: xev primary builder; xyz fallback builder)
**Date:** 2026-04-18
**Applies to:** `hosts/xev/configuration.nix`, `hosts/xyz/configuration.nix`, `hosts/mac/configuration.nix`, `modules/nixos/common/distributed-build-client.nix`, `modules/nixos/common/server.nix`, `packages/nix-deploy`

## Context

The repo's server hosts have constrained build capacity: nux is a modest x86_64
server, nex is better used as a Kubernetes control-plane member than a general
compiler, and rpi0 is an aarch64 ARM board where native compilation of anything
substantial is prohibitively slow. NixOS supports distributed builds, offloading
compilation to more powerful machines.

`xev` is now the always-on power server and should absorb normal build load.
`xyz` remains capable and keeps its builder role as the fallback when `xev` is
offline or saturated.

rpi0 specifically needs cross-architecture support: building aarch64 packages either requires native compilation on the slow board or a build host that supports aarch64 (via native hardware or binfmt/QEMU emulation on x86_64).

## Decision

`xev` acts as the primary remote build host for machines that explicitly enable
the distributed-build client capability. `xyz` remains configured as the
fallback remote build host:

```nix
nix.buildMachines = [
  {
    hostName = "xev";
    sshUser = "root";
    sshKey = "/root/.ssh/id_distributed_build";
    systems = [ "x86_64-linux" "aarch64-linux" ];
    maxJobs = 12;
    speedFactor = 3;
    supportedFeatures = [ "big-parallel" "kvm" ];
  }
  {
    hostName = "xyz";
    sshUser = "root";
    sshKey = "/root/.ssh/id_distributed_build";
    systems = [ "x86_64-linux" "aarch64-linux" ];
    maxJobs = 8;
    speedFactor = 2;
    supportedFeatures = [ "big-parallel" "kvm" ];
  }
];
nix.distributedBuilds = true;
```

A dedicated SSH key (`/root/.ssh/id_distributed_build`) is used exclusively for
build authentication. The current encrypted secret key name remains
`ssh_buildhost_xyz` for compatibility with existing host secret files, but its
meaning is now "fleet distributed build client key". The corresponding public
keys are authorized for `root@xev` and `root@xyz`.

aarch64 support on both x86_64 build hosts is provided via binfmt/QEMU
emulation.

The build-client private key is stored per participating host in `nix-secrets`
under `hosts/<host>/secrets.yaml` as `ssh_buildhost_xyz`, then deployed by
`modules/nixos/common/distributed-build-client.nix` to
`/root/.ssh/id_distributed_build`.

The deploy wrapper keeps `xyz` as the canonical `deploy --all` operator host,
but also supports `deploy --here` for temporary operator failover. In `--here`
mode, remote NixOS rebuilds intentionally omit `--build-host`; for
`nixos-rebuild --target-host`, that means the machine running the command builds
the closure before copying it to the target host. This is an operator workflow
fallback, not a target-host distributed-build configuration: on macOS it still
requires a working Linux builder before Linux targets can be built locally.

Remote deploy phases are preflighted over SSH before building. Explicit single
host deploys fail early when the required SSH endpoint is unreachable. Fleet
deploys skip unreachable hosts for the affected phase by default, with
`--fail-unreachable` available when the operator wants all-or-nothing behavior.
`--no-preflight` remains available for bootstrap and debugging cases where the
operator intentionally wants to attempt the deploy anyway.

Deploy SSH endpoints come from `inventory.nix`. Fixed LAN targets use their
reserved IP addresses as `sshHostname` values instead of relying on local name
resolution, because deployment is also a recovery path when DNS-like services
may be degraded.

`nix-deploy` remains packaged inside `nix-config` while it is coupled to the
public host inventory and flake output names. Moving it back to `nix-packages`
would split the generic executable from the repository-specific host data it
needs to generate its runtime host map. Reconsider moving it only if the tool is
made generic enough to consume an external inventory interface at runtime.

mac enables nix-darwin's stock Linux builder as a bootstrapping step. This
creates a `linux-builder` build machine for `aarch64-linux`, which lets mac
build and deploy rpi0 without asking rpi0 to compile locally. The builder is
left close to the nix-darwin default because changing the builder VM's NixOS
configuration before the first activation makes mac try to build Linux
derivations on Darwin. x86_64-linux emulation for nux/nex is intentionally a
follow-up after the initial Linux builder is active.

mac remains a cold-standby deploy/build coordinator, not normal fallback
capacity. The `deploy --here` path stays available for operator failover and
recovery drills, but the normal fleet workflow continues to prefer `xyz` as the
operator and `xev`/`xyz` as Linux builders.

## Alternatives Considered

- **Native builds on each host** — Rejected for rpi0. Compilation of non-trivial packages on ARM takes orders of magnitude longer; a full system rebuild would be impractical.
- **Hydra CI / remote build farm** — Rejected. Significant operational overhead for a personal setup; overkill when one powerful workstation is already available on the same network.
- **Cross-compilation from x86_64** — Considered as an alternative to binfmt emulation for aarch64. Cross-compilation is faster but has more failure modes (packages that don't cross-compile cleanly). binfmt emulation on xyz is simpler and more compatible.

## Consequences

- Deployments for nux, nex, and rpi0 are fast and practical, including full
  system rebuilds for rpi0.
- Server deployments prefer xev, then xyz. If both remote builders are
  unreachable, builds fall back to local execution where supported: slow on
  rpi0, acceptable on nux/nex for smaller changes.
- If xyz is unavailable, an operator can run `deploy --here --nixos <host>` or
  `deploy --here --all` from another capable machine. For non-`xyz` operators,
  `--here --all` deploys the remote server set (`nux`, `nex`, `rpi0`) and leaves
  `xyz` out of the fleet batch. From mac, rpi0 is the first supported Linux
  target after the Linux builder is activated; nux/nex need either xyz or the
  follow-up x86_64-linux builder work.
- mac is retained as a cold standby for emergency operation and validation
  drills only. It is not part of the normal builder priority path while `xev`
  and `xyz` are healthy.
- Unavailable hosts no longer force every ordinary fleet deploy to fail before
  useful reachable targets are updated. Strict fleet deploys can opt back into
  failure with `--fail-unreachable`.
- The local `nix-deploy` wrapper is intentionally owned by this repo for now,
  because its behavior is generated from `inventory.nix`.
- The build SSH key is declaratively deployed from each server host's SOPS file.
  Fresh installs still need enough SOPS bootstrap material to decrypt host
  secrets, but the build key itself is no longer a manual root dotfile.
- xev's own builds are local. xyz's own builds remain local unless it
  explicitly opts into distributed-build client credentials later.
  Distributed-build clients opt in with `alc.distributedBuildClient.enable =
  true`; server role alone does not imply build-client credentials.

## Follow-up Issues

Track the remaining build-orchestration work separately from the initial ADR
implementation PR:

1. [#78](https://git.alc.xyz/alcxyz/nix-config/issues/78) Enable and validate
   x86_64-linux support in mac's Linux builder for nux/nex after the stock
   aarch64 builder has been activated.
2. [#79](https://git.alc.xyz/alcxyz/nix-config/issues/79) Decide whether mac
   should remain an emergency build coordinator only or become a normal fallback
   in the operator runbook.
3. [#80](https://git.alc.xyz/alcxyz/nix-config/issues/80) Retire the fallback
   path or lower its priority when xyz is back in service.
