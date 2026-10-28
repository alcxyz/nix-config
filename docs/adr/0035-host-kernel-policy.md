# ADR-0035: Host kernel policy

**Status:** Accepted
**Date:** 2026-05-05
**Amended:** 2026-10-28
**History:** [replaced text](archive/0035-host-kernel-policy-history.md)
**Applies to:** `hosts/nux`, `hosts/nex`, `hosts/xyz`, `hosts/xev`, `hosts/rpi0`, `modules/nixos/hardware/zfs-latest-kernel.nix`, kernel selection

## Context

The k3s cluster has two Intel NUC-class stable workload hosts:

- `nux`: NUC k3s server + worker
- `nex`: second NUC k3s server + worker

When this policy was set, `nex` had booted the installer generation with Linux
7.0.3 while the flake default kernel from the pinned nixpkgs input was Linux
6.18.24.

The workstation `xyz` is different from the NUC servers. It has:

- NVIDIA proprietary driver configuration
- dynamic GPU passthrough hooks
- ZFS datasets and ZFS unlock/usage assumptions
- formerly an opportunistic k3s agent role, retired by
  [ADR-0061](0061-retire-xyz-k3s-agent.md); it was never part of control-plane
  quorum

`xev` also carries ZFS. On a ZFS host, the latest kernel is usable only with a
ZFS release whose declared kernel range covers it, and later nixpkgs locks have
repeatedly moved `pkgs.linuxPackages_latest` beyond what the packaged stable
OpenZFS supports. The current lock selects Linux 7.3, while stable OpenZFS
2.4.4 supports Linux 4.18 through 7.2.

## Decision

Use the latest kernel where the host role can tolerate it, with the flake lock
as the version boundary.

Use `pkgs.linuxPackages_latest` on the NUC-class k3s server hosts `nux` and
`nex`, and keep `rpi0` on it:

```nix
boot.kernelPackages = pkgs.linuxPackages_latest;
```

`xyz` and `xev` also track `pkgs.linuxPackages_latest`, through the shared
`modules/nixos/hardware/zfs-latest-kernel.nix` module, which extends the
kernel package set with a ZFS kernel module matched to the selected ZFS
userspace (`boot.zfs.package`). The module is built against the final selected
kernel, including its configuration overrides. Host storage helpers take their
ZFS tools from `boot.zfs.package`.

Prefer the packaged stable OpenZFS release over maintaining a
development-source pin or downgrading the kernel. Keep nixpkgs' compatibility
checks enabled, so a future unsupported kernel fails evaluation; do not
override the ZFS broken marker.

No packaged stable release supports Linux 7.3, so the current selection is a
pinned Linux 7.3 compatibility candidate. The operator chose to validate it in
[#788](https://git.alc.xyz/alcxyz/nix-config/issues/788#issuecomment-37173),
and it was adopted through
[#791](https://git.alc.xyz/alcxyz/nix-config/pulls/791). It is upstream
revision
[`cd3699d308e1b37dcdd0d5a9a8c3624deb5fc3e9`](https://github.com/openzfs/zfs/commit/cd3699d308e1b37dcdd0d5a9a8c3624deb5fc3e9),
the last accepted commit from the
[Linux 7.3 compatibility series](https://github.com/openzfs/zfs/pull/19082),
packaged as `openzfs_7_3` in `nix-packages` and selected through the filtered
package policy from ADR-0007. It contains the block iterator and CPU feature
API changes, flagless inode creation, and restored filesystem access for SPL
threads and taskqs. It is an unreleased development snapshot, not a stable
OpenZFS release.

Upstream's snapshot metadata still declares Linux 7.2 as its maximum. The
candidate applies an explicit local metadata patch for Linux 7.3, based on the
accepted compatibility code. Keep the generic builder's consistency checks and
upper compatibility bound, so a future unsupported kernel fails evaluation.
The metadata patch alone is not the compatibility implementation. The
snapshot includes other upstream changes, so keep its revision and source hash
fixed rather than following the development branch.

Future OpenZFS or kernel updates must keep the source revision, declared kernel
compatibility range, userspace tools and kernel module aligned.

The candidate was adopted after these checks
([#788](https://git.alc.xyz/alcxyz/nix-config/issues/788),
[#791](https://git.alc.xyz/alcxyz/nix-config/pulls/791)), and replacing it
needs the same validation:

- build matching userspace and kernel-module outputs and both complete `xyz`
  and `xev` system closures;
- pass the disposable Linux 7.3 VM check (`flake/checks/zfs-linux73-vm.nix`)
  for matching versions, file-vdev creation, cache writes, snapshot/rollback,
  scrub and export/import. It qualifies the selection without exercising
  existing pools or hardware;
- check active pool feature compatibility against the target release before
  any switch from the development snapshot to a stable release.

Building or publishing the configuration does not authorize activation,
reboot, or pool feature upgrades: these remain separate operations, and
adopting a candidate does not require pool upgrades.

Return to packaged stable ZFS once it supports the selected kernel, after the
same validation
([#792](https://git.alc.xyz/alcxyz/nix-config/issues/792)).

## Alternatives Considered

**Use the default kernel everywhere**: rejected for the NUC k3s servers because
newer Intel NUC hardware benefits from newer kernel support for firmware,
networking, NVMe, power management, and scheduler fixes. `nex` had already
booted successfully on a 7.x kernel.

**Keep the ZFS hosts on the default kernel**: `xyz` originally stayed on the
nixpkgs default kernel because ZFS for the latest kernel was marked broken.
Replaced once a ZFS release could be matched to the latest kernel.

**Override the ZFS broken check on `xyz`**: rejected. `xyz` has real ZFS data
and GPU/passthrough complexity; overriding the broken marker would convert an
explicit compatibility signal into runtime risk.

**Pin an explicit 7.x kernel package**: rejected. The desired policy is
"latest kernel where the host role can tolerate it", not a one-off kernel pin.
The flake lock remains the version boundary.

**Select Linux 7.2 with stable ZFS**: the alternative supported pairing to the
Linux 7.3 candidate, not selected. It would hold the ZFS hosts below the
kernel the lock selects, which is the kind of explicit kernel pin rejected
above: the policy tracks the latest kernel, with the flake lock as the version
boundary. Once a packaged stable release supports the selected kernel, prefer
it over the development pin.

**Backport the Linux 7.3 series onto stable 2.4.4**: rejected in favour of the
exact reviewed source; it also requires adapting CPU detection and inode/idmap
changes.

## Consequences

`nux`, `nex`, `xyz`, `xev` and `rpi0` all track the latest kernel in the lock;
on `xyz` and `xev` that is subject to the selected ZFS release's compatibility
checks, and a lock update can fail evaluation until a matching ZFS selection is
validated.

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

The earlier `openzfs-7-1` package remains in `nix-packages` for consumers that
still need it; this repository no longer applies it.
