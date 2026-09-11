# ADR-0071: Establish the shared container network namespace mount before runtimes

- Status: Accepted
- Date: 2026-09-10
- Area: containers, k3s, systemd

## Context

Container runtimes and CNI plugins keep network namespaces as mounts below
`/run/netns`. If that directory is made a separate shared mount after namespace
mounts already exist, the new mount can hide the older children. Runtime cleanup
then cannot unmount those namespaces through the visible path, and repeated
sandbox status and deletion operations can fail.

The invariant belongs to host configuration because Docker, embedded containerd,
and CNI components can all use this conventional path. A Kubernetes-only check
would miss other consumers and would require unnecessary API access.

## Decision

Hosts with Docker or k3s establish `/run/netns` as a shared mount before either
runtime starts. The preparation unit uses a recursive bind so any child mounts
that predate it remain in the resulting mount tree. It recursively detaches that
bind tree from any shared ancestor peer group before marking it recursively
shared. Otherwise a namespace mount can propagate back to the ancestor and
appear both inside and outside the intended `/run/netns` subtree. Both runtimes
require the unit and start after it.

Preparation changes mount topology only while systemd is still booting and both
runtimes are inactive. If the topology is already healthy, later service starts
may verify it without changing it. Otherwise the unit refuses runtime activation
and directs the operator to install the generation for boot and reboot. The unit
does not unmount or repair a live runtime namespace tree.

A timer audits mountinfo without Kubernetes credentials. It requires exactly one
shared `/run/netns` mount and verifies that every mount below that path reaches it
through the mount-parent graph. It also rejects a `/run/netns` root that shares
a propagation peer group with an ancestor mount, before runtime-created children
can expose the resulting shadow topology. Hosts with the existing storage health
monitor also report audit freshness through that monitor.

This change must be activated with `nixos-rebuild boot`, followed by the approved
host reboot workflow. It must not be activated with `nixos-rebuild switch` on a
running container host.

The disposable real-kernel fixture reproduces ancestor-peer propagation in a
private mount namespace, verifies the corrected topology, and confirms that the
initial mount namespace stays unchanged. It is deliberately excluded from the
ordinary unprivileged CI checks. Run it explicitly with:

```sh
nix-build --no-out-link --expr 'let pkgs = import <nixpkgs> {}; in import ./flake/checks/container-netns-vm.nix { inherit pkgs; }'
```

## Alternatives considered

### Store containerd network namespaces below its state directory

Containerd can place namespace mounts below its state directory. This is specific
to containerd, requires a runtime configuration override, and migration requires
all existing containers to be removed. It does not cover Docker's use of
`/run/netns`.

### Repair or remove stale mounts while runtimes are active

Live mount repair can invalidate namespaces still owned by containers and cannot
reliably distinguish hidden stale mounts from active ones. Recovery remains an
operator-controlled maintenance action.

## Consequences

- Runtime startup fails closed when the shared mount invariant cannot be safely
  established.
- Periodic topology failures are visible through ordinary systemd status and the
  existing host health signal where configured.
- Activation requires a boot generation and a controlled reboot.
