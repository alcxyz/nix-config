# ADR-0035: Host kernel policy

**Status:** Accepted
**Date:** 2026-05-05 (amended 2026-08-13, 2026-09-23)
**Applies to:** `hosts/nux`, `hosts/nex`, `hosts/xyz`, `hosts/xev`, `hosts/rpi0`, kernel selection

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

`xyz` originally remained on the nixpkgs default kernel until ZFS support for
the latest kernel evaluated cleanly. The 2026-08-13 amendment below replaces
that temporary exception.

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

The original policy allowed `nux` and `nex` to track newer kernels than `xyz`.
With the amendments below, `xyz` and `xev` also track the latest kernel, subject
to the selected ZFS release's compatibility checks.

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
checks, storage-detach gates, boot identity verification, workload settle
checks, and uncordon. See [ADR-0068](0068-k8s-node-power-lifecycle.md) for the full node power lifecycle.

## Amendment: Linux 7.1 on `xyz`

OpenZFS development revision
[`a35e8d892628d01e50af23aee5ba501be426baf6`](https://github.com/openzfs/zfs/commit/a35e8d892628d01e50af23aee5ba501be426baf6)
is the first upstream revision that declares Linux 7.1 compatibility. Stable
OpenZFS 2.4.3 and the corresponding nixpkgs package still declare Linux 7.0 as
their maximum supported kernel.

Pin that exact OpenZFS revision and source hash in the public `nix-packages`
flake as the narrowly scoped `openzfs-7-1` overlay. Apply only that named
overlay in `nix-config`; the filtered package policy from ADR-0007 remains in
place for the rest of `nix-packages`.

On `xyz`, select `pkgs.linuxPackages_latest` and extend its package set with a
matching `openzfs_7_1` kernel module. Use the same pinned revision for the ZFS
userspace tools. This replaces the temporary default-kernel policy for `xyz`.

The OpenZFS revision is an unreleased development snapshot, so adoption
requires more than evaluation: both userspace tools and the kernel module must
compile, and the complete `xyz` system closure must build before the change is
eligible for a separately approved activation. Building or publishing the
configuration does not authorize activation, reboot, or pool feature upgrades.

Future OpenZFS or kernel updates must keep the source revision, declared kernel
compatibility range, userspace tools, and kernel module aligned. Once a stable
OpenZFS release supports the selected kernel, replace the development pin with
that release after the same build validation.

## Amendment: stable OpenZFS with Linux 7.2

The updated nixpkgs lock selects Linux 7.2.7 for `linuxPackages_latest` and
removes the end-of-life Linux 7.1 package. The custom OpenZFS snapshot supports
only through Linux 7.1, so retaining it now fails the kernel compatibility check.

[OpenZFS 2.4.4](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.4) supports
Linux 4.18 through 7.2 and is already packaged as `pkgs.zfs_2_4` in this lock.
Use that stable package for userspace and its matching `zfs_2_4` module in
`pkgs.linuxPackages_latest`. Apply the same pairing to the shared ZFS kernel
module used by `xev`, and stop applying the custom `openzfs-7-1` overlay.

Prefer the packaged stable release over maintaining another development-source
pin or downgrading the kernel. Keep nixpkgs' compatibility checks enabled so a
future unsupported kernel fails evaluation. The old custom package remains in
`nix-packages` for consumers that still need it.

Validate the userspace and kernel-module outputs and the complete `xyz` system
closure before activation. Moving from a development snapshot to a stable branch
also requires checking active pool features against the target release before
rollout. Activation, reboot, and pool feature changes remain separate operations.
