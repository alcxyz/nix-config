# ADR-0057: Kubernetes-managed Wolf browser mobility

**Status:** Superseded by ADR-0061

**Date:** 2026-07-30

**Amended:** 2026-08-26

**Applies to:** `hosts/xyz`, `hosts/xev`, Wolf, public and protected browser
sessions, Kubernetes GPU workers

## Retirement amendment

ADR-0061 retires `xyz` as a k3s agent and browser fallback. Both browser
singletons now run only on `xev`; the guarded placement controller, worker
qualification DaemonSet, xyz attachment-node support, and automatic failover
described below are retired. The historical decision remains here to document
the migration and the single-writer constraints that still apply.

## Context

ADR-0056 established the protected browser as an independent Wolf coordinator
on `xev`. Its certificates, pairings, protected profile, and browser homes are
one private state tree, while Wolf starts disposable browser containers through
the node-local Docker API.

`xyz` has the preferred GPU for this workload, but it is also an interactive
workstation. It must remain easy to restart and must not become an etcd,
control-plane, or Longhorn replica-storage dependency. `xev` must remain able
to run the protected browser when `xyz` is unavailable without creating a
second writable copy of the browser state.

A qualification workload proved that `xyz` can join as a tainted k3s agent,
advertise its NVIDIA GPU, attach a Longhorn RWO volume whose three replicas
remain on stable storage nodes, detach that volume promptly, and restart its
k3s agent without interrupting local game processes.

The protected coordinator and its single-writer state have since been promoted
under Kubernetes, and planned fallback and return exercises preserved its Wolf
identity and browser homes. That work also showed that leaving public Wolf
host-native creates a second lifecycle and an implicit GPU-arbitration boundary
on `xev`. Kubernetes already owns the primitives needed to make that contention
explicit while preserving the two coordinator trust boundaries.

## Decision

Manage both Wolf coordinators under Kubernetes, but never combine them. The
public coordinator exposes cooperative Helium only. The protected coordinator
retains its independent selector, protected catalog, identity, pairing store,
client profile, and browser homes. Each coordinator has its own namespace,
singleton workload, RWO volume, Service, DNS name, backup identity, and rollback
path.

This amendment supersedes the original staging limit that kept public Helium
host-native. It does not supersede ADR-0056's separation of public and protected
Wolf.

Run one protected-browser supervisor Pod. Prefer `xyz` and allow `xev` as the
fallback worker. The supervisor owns exactly one node-local Wolf coordinator
and its browser runners. Use a `Recreate` rollout and a single RWO state volume;
never run two coordinators against the promoted state.

Run public Helium as a second singleton. Prefer `xev` and migrate its existing
state only after a fresh-profile shadow passes. Keep the host-native public
coordinator as a read-only rollback point until client, backup, and recovery
acceptance completes.

Retain Wolf's qualified Docker runner for the first migration. Replacing it
with a new Kubernetes-native application runner would combine an upstream
runtime rewrite with a state migration and is outside this milestone. The
supervisor may use the selected node's Docker API, but this broad capability is
an explicit trusted-host boundary:

- only the public-browser and private-browser namespaces may run their
  respective supervisors;
- the workload is restricted to declared protected-browser workers;
- the Docker socket and host devices are never exposed through a network
  service;
- the supervisor removes only its known coordinator and runner containers;
  and
- a later native runner may supersede this boundary in a separate ADR.

Wolf passes browser home directories to sibling Docker containers as host bind
mounts. A versioned launcher therefore resolves the PVC mount belonging to its
own Pod and passes that node-visible path as Wolf's host application-state
folder. It must derive the path from the Pod identity and mounted volume,
validate that it resolves to the expected Longhorn filesystem, and fail closed
instead of falling back to node-local state. Do not embed a transient kubelet
mount path in GitOps.

Both eligible hosts prepare the same pinned Wolf and browser images, separate
public and protected runtime paths, NVIDIA CDI support, virtual-input devices,
and both isolated Moonlight firewall port sets. Worker preparation must not
start either coordinator outside its Kubernetes supervisor.

Keep protected profile definitions, PINs, pairing authority, endpoint
assignments, and migration procedures in private configuration. Public Nix and
GitOps configuration declares only generic runtime interfaces and workload
policy.

## Stable services and GPU arbitration

Expose each coordinator through an independent LAN `LoadBalancer` Service. A
stable VIP follows the ready singleton endpoint; private DNS gives that VIP a
durable client name. DNS does not select between workers, and clients must not
carry alternate worker addresses. Keep cluster-wide Service forwarding while
the preferred disposable worker is not part of the stable load-balancer speaker
set.

Advertise exactly two time-sliced `nvidia.com/gpu` shares per qualified physical
GPU. Each Wolf singleton requests one share, requests larger than one are
rejected, and a third Kubernetes GPU workload is not admitted without a new
capacity decision. Prefer protected Wolf on `xyz` and public Wolf on `xev`, but
allow either singleton to use either qualified worker.

Time-slicing is scheduler overcommit rather than GPU partitioning. It does not
isolate VRAM, faults, or performance, and host-native GPU consumers remain
outside Kubernetes accounting. Protected Wolf retains higher priority if the
two advertised shares are exhausted.

Preferred node affinity affects initial placement but does not move an already
healthy Pod home. Use a controlled reconciliation step to return each singleton
to its preferred worker.

## State and rollout

Use one expandable Longhorn RWO volume per coordinator for Wolf configuration,
pairings, and browser homes. Retain the promoted protected volume at 10 GiB.
Start public Wolf at 5 GiB based on measured state plus growth headroom. Keep
container images and build caches outside both volumes, and expand a filesystem
before sustained usage exceeds roughly 70 to 75 percent.

Each volume uses three replicas on the stable Longhorn storage pool; `xyz` may
attach a volume but stores no replica. Replication is not a backup. Both volumes
must complete the recurring off-volume backup policy and a disposable restore
test before their host-native rollback point is retired.

The protected migration completed its original four gates:

1. Run a parked shadow workload with a fresh, non-production profile on `xyz`.
2. Quiesce the host-native protected coordinator, seed and verify the real
   state, then perform a final delta before promotion.
3. Qualify a planned `xyz` restart, `xev` fallback, and return to `xyz`.
4. Retire the host-native protected coordinator only after a bounded rollback
   window.

Continue in six follow-up gates:

1. Restore protected-volume replica health and prove backup and restore.
2. Add the stable protected Service and move every private client profile to it.
3. Shadow, quiesce, migrate, and verify public Helium as a separate workload.
4. Prepare both runtime roots and Moonlight port sets on every qualified worker.
5. Enable two time-sliced shares, make public Wolf eligible for both workers,
   and qualify simultaneous admission, worker loss, priority, and failback.
6. Revalidate all clients and regression boundaries before retiring host-native
   public Wolf.

Keep former host-native state read-only during each rollback window. Rollback
selects one authoritative copy; it never merges two writable browser trees.

## Consequences

`xyz` can provide the preferred protected encoder without becoming a durable
cluster dependency. A longer `xyz` outage can move the same protected browser
state to `xev`, while a short workstation restart can return before failover
begins. Public Helium can fall back to `xyz`, and both singletons can remain
admitted when only one qualified physical GPU is available.

Time-slicing removes the scheduler admission deadlock but does not create more
GPU capacity. Concurrent browser sessions or a host-native GPU workload may
degrade one another.

The first implementation is not a pure containerd workload: Kubernetes owns
placement, storage attachment, and supervisor lifecycle, while Wolf retains its
qualified node-local Docker runner. This preserves current browser behavior but
requires a narrow, audited privileged boundary and identical image preparation
on both workers.

Stable Services remove worker addresses from Moonlight configuration, but they
do not merge identities or pairing stores. Steam/game containers, physical
input, KDE Connect, Synergy, and concurrent Moonlight clients remain independent
regression boundaries.

## Alternatives considered

### Make `xyz` a normal Longhorn storage node

Rejected because workstation shutdown would remove a steady-state replica
failure domain and lengthen maintenance through storage rebuilds.

### Synchronize independent writable browser trees on `xyz` and `xev`

Rejected because browser databases, singleton files, certificates, and profile
locks are not safe to merge after concurrent writes.

### Rewrite Wolf to launch Kubernetes Pods before migrating

Deferred. It could remove the Docker socket boundary, but it is a larger runtime
change than required to establish safe single-writer mobility.

### Use RWX/NFS for simultaneous access

Rejected. The protected coordinator is a singleton, and RWO avoids an
unnecessary NFS layer for browser database and profile hot paths.

### Combine public Helium with the protected coordinator

Rejected. A shared coordinator would collapse catalog visibility, pairing,
profile, and recovery boundaries that ADR-0056 intentionally separated.

### Keep public Helium host-native permanently

Rejected as the target state. It retains a separate lifecycle and leaves GPU
contention outside Kubernetes scheduling. The host-native service remains only
as a bounded migration rollback point.

## Tracking

- Forgejo milestone: **Kubernetes Wolf browser mobility**
- Completed migration issues: #187–#190
- Issue #203: stable private Wolf Service and client endpoint
- Issue #204: independent public Helium Kubernetes migration
- Issue #205: GPU priority and controlled failback
- Issue #206: capacity, replica, backup, and restore qualification
- Issue #207: dual-client acceptance and host-native public retirement
