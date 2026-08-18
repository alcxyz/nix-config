# ADR-0040: UniFi automatic HA target

**Status:** Retired (2026-08-19)
**Date:** 2026-05-07
**Applies to:** `modules/nixos/services/unifi-native/`, `hosts/nux`, `hosts/rpi0`, UniFi fallback automation

This proposal was retired when the Network Application moved to a gateway
console. Host-level controller failover is no longer a target.

## Context

UniFi now runs as a native NixOS service, with a prepared cold standby. The
standby host has the required unit, packages, users, state directories,
firewall rules, and local DNS integration, but it does not run UniFi at boot.

That gives a workable disaster fallback, but it is not automatic HA:

- backups still need to be present on `rpi0`
- promotion requires operator action
- DNS still needs a clear active-controller authority model
- split-brain prevention is not yet encoded
- return-to-primary is manual

## Decision

Move toward automatic HA in phases, with an explicit bias toward correctness over
instant failover.

The target design is:

- `nux` remains the preferred active controller.
- `rpi0` remains the standby controller and can be promoted.
- A neutral active-controller DNS name points clients/operators at the active
  side.
- `nux` exports scheduled UniFi backups and replicates them to `rpi0`.
- Promotion is implemented as an explicit guarded command before any fully
  automatic promotion is enabled.
- Automatic promotion requires health checks, stale-backup checks, and
  split-brain guardrails.

## Work Items

- [nix-config#42](https://git.alc.xyz/alcxyz/nix-config/issues/42): define active-controller DNS and failover authority.
- [nix-config#43](https://git.alc.xyz/alcxyz/nix-config/issues/43): automate backup export and replication to `rpi0`.
- [nix-config#44](https://git.alc.xyz/alcxyz/nix-config/issues/44): implement standby promotion and demotion commands.
- [nix-config#45](https://git.alc.xyz/alcxyz/nix-config/issues/45): add health checks and automatic promotion policy.
- [nix-config#46](https://git.alc.xyz/alcxyz/nix-config/issues/46): rehearse failover and return-to-primary.

## Alternatives Considered

- **Keep cold standby only** — acceptable as a short-term state, but still
  depends on manual backup location, restore, service start, and DNS changes
  during an outage.
- **Immediate automatic failover** — rejected for now. A UniFi controller can
  create operational side effects around adoption, inform URLs, and device
  provisioning. Automatic promotion without stale-backup and split-brain
  controls is too risky.
- **Run both controllers active** — rejected. UniFi does not support two active
  controllers owning the same site/devices.

## Consequences

- The current cold standby remains the safe fallback until the work items are
  complete.
- The first automation should improve restore readiness, not immediately start
  doing automatic promotion.
- Full automatic HA is only acceptable after a successful controlled failover
  and return-to-primary drill.
