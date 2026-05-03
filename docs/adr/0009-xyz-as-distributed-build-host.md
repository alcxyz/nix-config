# ADR-0009: xyz as the distributed build host for server machines

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/common/server.nix`

## Context

The repo's server hosts have constrained build capacity: nux is a modest x86_64 server, and rpi0 is an aarch64 ARM board where native compilation of anything substantial is prohibitively slow. NixOS supports distributed builds, offloading compilation to a more powerful machine. xyz, as the primary workstation with significant CPU resources and KVM support, is the natural candidate.

rpi0 specifically needs cross-architecture support: building aarch64 packages either requires native compilation on the slow board or a build host that supports aarch64 (via native hardware or binfmt/QEMU emulation on x86_64).

## Decision

xyz acts as the remote build host for all server-role machines. Configured in `modules/nixos/common/server.nix`, which all server-role hosts import:

```nix
nix.buildMachines = [{
  hostName = "xyz";
  sshUser = "root";
  sshKey = "/root/.ssh/id_buildhost_xyz";
  systems = [ "x86_64-linux" "aarch64-linux" ];
  maxJobs = 4;
  speedFactor = 2;
  supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
}];
nix.distributedBuilds = true;
```

A dedicated SSH key (`/root/.ssh/id_buildhost_xyz`) is used exclusively for build authentication. aarch64 support on xyz is provided via binfmt/QEMU emulation.

The build-client private key is stored per server host in `nix-secrets` under
`hosts/<host>/secrets.yaml` as `ssh_buildhost_xyz`, then deployed by
`modules/nixos/common/server.nix` to `/root/.ssh/id_buildhost_xyz`. The matching
public keys are authorized only for `root@xyz`.

## Alternatives Considered

- **Native builds on each host** — Rejected for rpi0. Compilation of non-trivial packages on ARM takes orders of magnitude longer; a full system rebuild would be impractical.
- **Hydra CI / remote build farm** — Rejected. Significant operational overhead for a personal setup; overkill when one powerful workstation is already available on the same network.
- **Cross-compilation from x86_64** — Considered as an alternative to binfmt emulation for aarch64. Cross-compilation is faster but has more failure modes (packages that don't cross-compile cleanly). binfmt emulation on xyz is simpler and more compatible.

## Consequences

- Deployments for nux and rpi0 are fast and practical, including full system rebuilds for rpi0.
- Server deployments depend on xyz being online. If xyz is unreachable, builds fall back to local execution — slow on rpi0, acceptable on nux for most packages.
- The build SSH key is declaratively deployed from each server host's SOPS file.
  Fresh installs still need enough SOPS bootstrap material to decrypt host
  secrets, but the build key itself is no longer a manual root dotfile.
- xyz's own builds are local — only hosts importing `server.nix` have distributed builds configured. Do not remove `nix.distributedBuilds` from `server.nix` assuming it is inactive.
