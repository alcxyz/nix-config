# ADR-0047: Kubernetes API floating VIP

**Status:** Accepted
**Date:** 2026-05-12
**Amended:** 2026-11-03 (functional readiness, per the [accepted answer](https://git.alc.xyz/alcxyz/nix-config/issues/753#issuecomment-33770))
**History:** [replaced text](archive/0047-k8s-api-vip-history.md)
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
keepalived on the k3s server nodes (`nux`, `nex` and `xev`, through
`services.k8s-api-vip` in `modules/nixos/services/k8s-api-vip/`), assign the
address to one ready server at a time, and move it when that server's local
API becomes unready.

Clients and joining nodes use one stable API name. The k3s certificates include
that stable identity. The endpoint follows the accepted server set
([ADR-0017](0017-k3s-cluster-topology.md)), which includes `xev` in place of
`rpi0` ([ADR-0051](0051-xev-replaces-rpi0-k3s-server.md)).

The floating address provides failover, not request distribution, and does not
change embedded-etcd quorum requirements.

## Readiness and withdrawal contract

Eligibility requires a completed HTTPS GET to the local API's `/readyz` on
loopback with HTTP status **200**, without excluding any checks. The
[Kubernetes readiness contract](https://kubernetes.io/docs/reference/using-api/health-checks/)
includes etcd availability and initialization, unlike a TCP listener probe.
Redirects, authentication or authorization failures, other HTTP statuses,
connection failures and timeouts do not qualify. This predicate concerns API
traffic, separate from the deployment readiness gate and node self-fencing.

The probe first tries anonymous readiness, bypassing proxies and curl
configuration. [Pinned K3s disables anonymous API authentication by
default](https://github.com/k3s-io/k3s/blob/v1.36.5%2Bk3s1/pkg/daemons/control/server.go#L207-L208),
so only a completed 401 or 403 triggers a second request using the existing
local kube-proxy client certificate and key. This non-admin component identity
is less privileged than the existing administrator, supervisor, controller and
scheduler clients; [default authenticated-user
RBAC](https://github.com/kubernetes/kubernetes/blob/v1.36.5/plugin/pkg/auth/authorizer/rbac/bootstrappolicy/policy.go#L649)
permits reading `/readyz`. The module creates no identity, credential or RBAC
grant. The `readinessClient` interface accepts existing runtime certificate
and key paths, or null for anonymous-only operation. `readinessCaFile`
supplies the existing server CA for both request paths. Nonstandard K3s data
directories need matching paths. Files are opened anew for every request so
rotation needs no cached credential refresh.

Both anonymous and authenticated requests verify the local API server against
the existing CA, preventing an arbitrary local TLS listener from qualifying.
Missing, expired or denied credentials, TLS failures and non-200 readiness all
fail closed. If neither anonymous readiness nor the existing least privileged
client works, report the blocker and stop rollout rather than create a secret,
grant access or use administrator credentials.

Keepalived starts the readiness track script failed (`init_fail`). Probes run
at two-second intervals with a two-second deadline per request and a
five-second script timeout (at most two sequential requests). Two consecutive
successes admit an instance; two consecutive failures put it in FAULT. Zero
tracking weight removes an unready instance from the election and withdraws
its address even when every peer is unready. Ready instances use the existing
priority and non-preempting election: recovery does not displace a holder that
remains ready. Sampling, hysteresis and VRRP convergence introduce a delay;
this is not instantaneous failover or a global split-brain guarantee under
network partition.

Synthetic qualification uses the production probe and keepalived configuration
with controlled HTTPS readiness responses. It covers initial ineligibility,
ready-instance election, failure with a TCP listener still open, all-unready
withdrawal and recovery. It does not establish live API readiness semantics or
network behavior. Before rollout, qualify anonymous access or the existing
client and the full readiness predicate, single-instance failover, all-unready
withdrawal (including quorum loss) and recovery in an authorized maintenance
window. Include a cold restart of initialized members while the VIP is absent,
to qualify that quorum and local readiness can recover without the stable
endpoint. Record results and observed convergence times in the owning issue;
source validation alone does not authorize deployment or establish runtime
acceptance.
## Alternatives Considered

**Keep a fixed server endpoint**: rejected because client access would still
fail with that server even when control-plane quorum remained healthy.

**Use DNS round-robin**: rejected because ordinary client and resolver behavior
does not provide dependable health-aware failover.

**Add a proxy tier**: rejected because direct address ownership by the API
servers meets the availability requirement without another runtime component.

**Manage the endpoint inside Kubernetes**: rejected because the endpoint is
needed to reach and recover Kubernetes itself.

**Use a dedicated load-balancer host**: rejected because that would introduce
another machine dependency.

## Consequences

Clients retain one API identity while address ownership can move between ready
servers. **The VIP disappears during quorum loss when every local API is
unready**, and returns only after an instance qualifies again. A listening but
unready server does not preserve the endpoint for diagnosis or recovery.
Availability still depends on embedded-etcd quorum, and changes to the server
set, API version or authentication policy require readiness and failover
qualification.
