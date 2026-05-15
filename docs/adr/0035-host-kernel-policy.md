# ADR-0035: Host kernel policy

**Status:** Accepted
**Date:** 2026-05-05
**Applies to:** `hosts/nux`, `hosts/nex`, `hosts/xyz`, `hosts/rpi0`, kernel selection

## Context

The k3s cluster now has two Intel NUC-class stable workload hosts:

- `nux` — existing NUC k3s server + worker
- `nex` — second NUC k3s server + worker

`nex` initially booted the installer generation with Linux 7.0.3, while the
flake default kernel from the pinned nixpkgs input was Linux 6.18.24. In the
current flake lock, `pkgs.linuxPackages_latest` resolves to Linux 7.0.1.

The workstation `xyz` is different from the NUC servers. It has:

- NVIDIA proprietary driver configuration
- dynamic GPU passthrough hooks
- ZFS datasets and ZFS unlock/usage assumptions
- opportunistic k3s agent role, not stable control-plane quorum

A temporary evaluation of `xyz` with `boot.kernelPackages =
pkgs.linuxPackages_latest` selected Linux 7.0.1 and NVIDIA
`nvidia-x11-580.142-7.0.1`, but the full system dry-run failed because
`zfs-kernel-2.4.1-7.0.1` is marked broken in the pinned nixpkgs revision.

## Decision

Use `pkgs.linuxPackages_latest` on NUC-class k3s server hosts:

```nix
boot.kernelPackages = pkgs.linuxPackages_latest;
```

This applies to:

- `nux`
- `nex`

Keep `xyz` on the nixpkgs default kernel until ZFS support for the latest kernel
evaluates cleanly in the pinned nixpkgs revision.

Keep `rpi0` on `pkgs.linuxPackages_latest`; it already used that policy before
this ADR.

## Alternatives Considered

**Use the default kernel everywhere** — rejected for the NUC k3s servers because
newer Intel NUC hardware benefits from newer kernel support for firmware,
networking, NVMe, power management, and scheduler fixes. `nex` has already
booted successfully on a 7.x kernel.

**Use `linuxPackages_latest` everywhere, including `xyz`** — rejected for now
because `xyz` fails full system evaluation with Linux 7.0.1 due to broken ZFS
kernel package support in the current nixpkgs lock.

**Override the ZFS broken check on `xyz`** — rejected. `xyz` has real ZFS data
and GPU/passthrough complexity; overriding the broken marker would convert an
explicit compatibility signal into runtime risk.

**Pin an explicit 7.x kernel package** — rejected for now. The desired policy is
"latest kernel where the host role can tolerate it", not a one-off kernel pin.
The flake lock remains the version boundary.

## Consequences

`nux` and `nex` will track newer kernels than `xyz` under the same nixpkgs lock.
This is intentional because the NUCs are simpler server hosts and are the stable
k3s control-plane/workload machines.

Kernel rollout should still be staged:

1. Switch `nex` first.
2. Reboot `nex` through the shared Kubernetes reboot helper.
3. Verify `nex` rejoins k3s as `Ready` and the helper's cluster health checks
   pass.
4. Switch `nux`.
5. Reboot `nux` through the shared Kubernetes reboot helper.
6. Verify k3s control-plane health and workload scheduling.

Do not use a raw host reboot for schedulable k3s nodes during routine
maintenance. The helper is responsible for cordon/drain, Longhorn-aware health
checks, workload settle checks, and uncordon.

`xyz` can be reconsidered for `linuxPackages_latest` when a dry-run of the full
system no longer fails on ZFS for the latest kernel.
