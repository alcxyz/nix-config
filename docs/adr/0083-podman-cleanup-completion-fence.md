# ADR-0083: Fence admission until Podman cleanup completion is known

**Status:** Accepted; recovery and deployment require qualification
**Date:** 2026-10-06
**Applies to:** idle Podman runner cleanup and aggregate admission

## Context

A bounded HTTP client does not bound stock Podman storage mutation. Podman
5.8.7 image removal reaches storage deletion without a cancellation context;
client disconnection therefore does not prove completion. Bulk image prune
also performs Buildah cache-mount cleanup when selecting all unused images.
These semantics invalidate release of admission based only on client exit or
an available lifecycle lock.

## Decision

Use capped, sequential deletion of the oldest unused image IDs beyond the
creation-age cutoff. Preserve referenced, recent, multitag and parent images.
Docker-compatible deletion uses `force=false` and `noprune=true`; do not invoke
bulk image prune or cache-mount cleanup. Retain existing request and service
budgets, lifecycle exclusion and terminal-job checks. A pass may do partial
work within its budget.

Before each destructive request, create an independently owned, trusted runtime
completion fence under the lifecycle lock. Clear it only on a validated complete
acknowledgement belonging to that request. Timeout, disconnect, helper death,
partial responses and uncertain errors leave it intact. Existing or malformed
fences block further cleanup, both runner start gates, guard resume and both
dedicated API starts even after the lock is released. API admission uses fixed
root-executed conditions under the shared lifecycle lock. Docker's condition
checks only the cleanup fence, retaining ordinary Docker-only boot ordering;
Podman's existing registry and controller checks remain in force. The guard remains healthy; freeze,
thaw, teardown and manually stopped runner ownership remain independent.

Record both API execution generations before mutation. Do not infer recovery
from elapsed time, attempts, read-only API success or PID changes. An explicit
operator-invoked recovery command verifies trusted fence ownership and format,
the exact runner registry, terminal API generation evidence, and fully terminal runners
and APIs without main/control processes or pending jobs. It requires positive
unpopulated evidence for the exact managed aggregate and any retained unit
cgroups, with a running systemd freezer and unfrozen kernel state. Repeat the
complete terminal evidence under the same lifecycle lock used by runner and API
start conditions; queued and activating starts, including starts whose conditions
already passed, withhold recovery. Uncertain or changed evidence leaves the
fence intact. Systemd clears its execution timestamp after a clean stop: a zero
current generation is accepted only with complete terminal unit proof and
positive empty-worker evidence, never on its own. A different positive generation
withholds recovery. Clear only verified owned fence files, preserving independent
freeze, drain and teardown ownership. The command never stops, starts or resets
units and provides no automatic recovery. Reboot clears runtime state.
Operational qualification and recovery procedures remain private.

## Alternatives Considered

- Longer client deadlines or presumed request cancellation do not establish
  storage completion and increase the blocked admission interval.
- Holding locks indefinitely conflicts with bounded lifecycle and service
  budgets and still cannot survive helper death.
- A server completion protocol would establish a stronger boundary, but stock
  Podman provides no suitable operation receipt for this path.
- Terminal snapshots without excluding both API starts leave a worker-creation
  race. Extending Podman's dual-runner health gate to ordinary Docker boot would
  change its startup contract and could invert lifecycle ordering. A fence-only
  condition at the dedicated Docker unit boundary closes the race without those
  extra dependencies.

## Consequences

Bounded cleanup no longer silently reopens admission while storage work may
continue. Ambiguous completion deliberately costs CI availability until positive
recovery or reboot. Individual deletes avoid unfiltered cache-mount cleanup and
may reclaim less per pass. A retained fence keeps later cleanup runs failed,
including outside a cleanup window; optional recent-success health monitoring
checks that current failure before accepting an earlier success.
Per-host qualification remains required by
[ADR-0072](0072-isolated-runner-docker.md) and
[ADR-0074](0074-phased-podman-coexistence.md).

Source contract: Podman 5.8.7
[image removal handler](https://github.com/podman-container-tools/podman/blob/v5.8.7/pkg/api/handlers/compat/images_remove.go),
[image prune implementation](https://github.com/podman-container-tools/podman/blob/v5.8.7/pkg/domain/infra/abi/images.go),
[libimage removal](https://github.com/podman-container-tools/podman/blob/v5.8.7/vendor/go.podman.io/common/libimage/image.go)
and [storage deletion](https://github.com/podman-container-tools/podman/blob/v5.8.7/vendor/go.podman.io/storage/store.go).

Tracks [#538](https://git.alc.xyz/alcxyz/nix-config/issues/538).
