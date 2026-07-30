# ADR-0057: Kubernetes-managed protected browser mobility

**Status:** Accepted, staged

**Date:** 2026-07-30

**Applies to:** `hosts/xyz`, `hosts/xev`, Wolf, protected browser sessions,
Kubernetes GPU workers

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

## Decision

Move only the protected browser coordinator under Kubernetes lifecycle
management. Keep the public Helium coordinator host-native on `xev`.

Run one protected-browser supervisor Pod. Prefer `xyz` and allow `xev` as the
fallback worker. The supervisor owns exactly one node-local Wolf coordinator
and its browser runners. Use a `Recreate` rollout and a single RWO state volume;
never run two coordinators against the promoted state.

Retain Wolf's qualified Docker runner for the first migration. Replacing it
with a new Kubernetes-native application runner would combine an upstream
runtime rewrite with a state migration and is outside this milestone. The
supervisor may use the selected node's Docker API, but this broad capability is
an explicit trusted-host boundary:

- only the protected-browser namespace may run the supervisor;
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

Both eligible hosts prepare the same pinned Wolf and browser images, stable
runtime helper paths, NVIDIA CDI support, virtual-input devices, and firewall
policy. Add a worker/preparation mode to the reusable Wolf module so `xyz` can
prepare artifacts without starting public or protected coordinators. `xev`
continues to run public Wolf while also retaining the artifacts required for
protected-browser fallback.

Keep protected profile definitions, PINs, pairing authority, endpoint
assignments, and migration procedures in private configuration. Public Nix and
GitOps configuration declares only generic runtime interfaces and workload
policy.

## State and rollout

Use one expandable Longhorn RWO volume for Wolf configuration, pairings, and
browser homes. Its durable replicas remain on the stable Longhorn storage pool;
`xyz` may attach the volume but stores no replica.

Roll out in four gates:

1. Run a parked shadow workload with a fresh, non-production profile on `xyz`.
2. Quiesce the host-native protected coordinator, seed and verify the real
   state, then perform a final delta before promotion.
3. Qualify a planned `xyz` restart, `xev` fallback, and return to `xyz`.
4. Retire the host-native protected coordinator only after a bounded rollback
   window.

Keep the former `xev` state read-only during the rollback window. Rollback
selects one authoritative copy; it never merges two writable browser trees.

## Consequences

`xyz` can provide the preferred encoder without becoming a durable cluster
dependency. A longer `xyz` outage can move the same protected browser state to
`xev`, while a short workstation restart can return before failover begins.

The first implementation is not a pure containerd workload: Kubernetes owns
placement, storage attachment, and supervisor lifecycle, while Wolf retains its
qualified node-local Docker runner. This preserves current browser behavior but
requires a narrow, audited privileged boundary and identical image preparation
on both workers.

The public browser, Steam/game containers, physical input, KDE Connect,
Synergy, and concurrent Moonlight clients remain independent regression
boundaries.

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

## Tracking

- Forgejo milestone: **Kubernetes private browser mobility**
- Issue #187: shadow runtime
- Issue #188: state migration and rollback
- Issue #189: restart and fallback qualification
- Issue #190: host-native retirement
