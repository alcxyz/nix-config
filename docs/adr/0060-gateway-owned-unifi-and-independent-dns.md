# ADR-0060: Gateway-owned UniFi and independent DNS pair

**Status:** Accepted
**Date:** 2026-08-20
**Applies to:** UniFi runtime ownership, native DNS services, gateway DHCP

## Context

The previous design ran the UniFi Network Application on a general-purpose
NixOS host and prepared another host as a cold standby. DNS also depended on one
of those hosts. That design added backup, promotion, split-brain, and lifecycle
work around services that should remain available independently of Kubernetes.

The replacement gateway includes the Network Application. A second native DNS
host is also available, so controller ownership and DNS availability no longer
need to share a failure domain.

## Decision

- The gateway console owns the UniFi Network Application runtime, upgrades,
  device adoption, and console-native backup/restore lifecycle.
- No general-purpose NixOS host runs an active or standby UniFi controller.
- GitOps continues to own selected reviewed UniFi desired state and the stable
  operator route, without owning the console runtime.
- Pi-hole and Unbound run as a two-host native NixOS resolver pair outside k3s.
- Gateway DHCP advertises both resolvers; GitOps owns that selected DHCP desired
  state, while Pi-hole OpenTofu owns local DNS records.
- Private addresses, credentials, recovery material, and host-specific secret
  defaults remain in the private infrastructure repository.

## Alternatives considered

- **Keep host-managed active/passive UniFi:** rejected because it duplicates a
  controller already integrated with the gateway and retains unnecessary
  failover machinery.
- **Move UniFi or DNS into Kubernetes:** rejected because loss of the cluster
  must not remove the network control plane or LAN name resolution.
- **Keep one resolver:** rejected because the second native host provides a
  simple independent fallback without coupling DNS to the cluster.

## Consequences

- ADR-0038 and ADR-0040 are retired, and their host failover work items are
  superseded.
- The previous controller host can be rebuilt without restoring UniFi or DNS
  services.
- Network application snapshots are console-native; NixOS snapshots cover only
  host-managed services.
- Compatibility route names may outlive the former hosts temporarily, but must
  be documented as aliases rather than current runtime ownership.
