# ADR-0038: UniFi native NixOS active/passive runtime

**Status:** Accepted
**Date:** 2026-05-06
**Applies to:** `modules/nixos/services/unifi-native/`, `hosts/nux`, `hosts/rpi0`

## Context

The UniFi Network Application has been one of the last host-infrastructure
services still running from Docker Compose on `nux`. Docker Compose no longer
adds much value for this service:

- the rest of the infrastructure is increasingly managed through NixOS modules
- UniFi is host infrastructure, not a k8s workload
- fallback should be prepared on `rpi0` without depending on k8s
- the pinned NixOS module provides UniFi 10.2.105 with MongoDB 7.0, matching the
  current Docker Mongo major version

## Decision

Run UniFi through a repo-local NixOS wrapper module named
`services.unifi-native`.

- `nux` is the active controller.
- `rpi0` is the fallback host. It has the native UniFi unit, packages, users,
  state directories, and firewall policy declared, but the service is not wanted
  at boot.
- The module wraps upstream `services.unifi` rather than duplicating its
  systemd implementation.
- The module opens the full set of local controller ports, including `8443/tcp`
  for UI/API access.
- Migration and fallback should use UniFi backup/restore artifacts, not raw
  Docker Mongo volume copying.

The existing Pi-hole wrapper option is renamed from `services.alc-pihole-native`
to `services.pihole-native`; the old option remains available through a NixOS
renamed-option module during transition.

## Alternatives Considered

- **Keep Docker Compose** — works, but leaves UniFi outside the NixOS host model
  and keeps a legacy runtime path around for one service.
- **Move UniFi into k8s** — rejected. UniFi is network infrastructure and should
  remain available independently of the cluster.
- **Raw Mongo data migration** — rejected for the first migration. UniFi `.unf`
  backup/restore gives a cleaner rollback boundary and avoids coupling to the
  Docker volume layout.

## Consequences

- Rebuilding `nux` can manage the UniFi runtime declaratively.
- The Docker UniFi containers must be stopped before enabling the native service
  because they bind the same host ports.
- The first migration still needs an operational restore step through the UniFi
  UI/API.
- `rpi0` fallback still requires restoring a current UniFi backup before
  starting the service.
- Because the standby service unit exists but is not wanted at boot, failover can
  start UniFi manually after restore without rebuilding just to create the unit.
- The operational fallback flow is documented in
  [`../unifi-native-fallback-runbook.md`](../unifi-native-fallback-runbook.md).
