# ADR-0047: Kubernetes API floating VIP

**Status:** Accepted (amended 2026-05-31: `xev` replaced `rpi0`)
**Date:** 2026-05-12
**Applies to:** Kubernetes API availability, k3s servers, and client configuration

## Context

An embedded-etcd quorum lets the control plane survive a server outage, but a
client endpoint tied to one server remains a separate single point of failure.
The API therefore needs a stable endpoint whose ownership follows a healthy
server.

Detailed addressing, peer configuration, election policy, resolution, and
recovery procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Use a host-managed floating virtual address for the Kubernetes API. Run
keepalived on the k3s server nodes, assign the address to one healthy server at a
time, and move it when that server's local API is unavailable.

Clients and joining nodes use one stable API name. The k3s certificates include
that stable identity. The endpoint follows the accepted server set, including
the membership change recorded by
[ADR-0051](0051-xev-replaces-rpi0-k3s-server.md).

The floating address provides failover, not request distribution, and does not
change embedded-etcd quorum requirements.

## Alternatives Considered

**Keep a fixed server endpoint** — rejected because client access would still
fail with that server even when control-plane quorum remained healthy.

**Use DNS round-robin** — rejected because ordinary client and resolver behavior
does not provide dependable health-aware failover.

**Add a proxy tier** — rejected because direct address ownership by the API
servers meets the availability requirement without another runtime component.

**Manage the endpoint inside Kubernetes** — rejected because the endpoint is
needed to reach and recover Kubernetes itself.

**Use a dedicated load-balancer host** — rejected because that would introduce
another machine dependency.

## Consequences

Clients retain one API identity while address ownership can move between healthy
servers. Availability still depends on embedded-etcd quorum, and changes to the
server set require coordinated updates and failover validation.
