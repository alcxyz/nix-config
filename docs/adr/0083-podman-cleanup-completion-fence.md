# ADR-0083: Fence admission until Podman cleanup completion is known

**Status:** Accepted; recovery and deployment require qualification
**Date:** 2026-10-06
**Applies to:** idle runner cleanup and aggregate admission
**Amended:** 2026-10-17, exited containers outside pods follow capped per-ID deletion like images, newest first ([#719](https://git.alc.xyz/alcxyz/nix-config/issues/719)).
**Amended:** 2026-10-17, the fence, cleanup window and recovery cover every runner in the configured list, which may hold more than one Podman runner ([#680](https://git.alc.xyz/alcxyz/nix-config/issues/680)).

**Amended:** 2026-10-25, standalone container candidates share one validated newest-first queue ([#833](https://git.alc.xyz/alcxyz/nix-config/issues/833)).
**Amended:** 2026-10-29, cleanup starts and dispatches each destructive request only at or below the pressure guard's I/O resume threshold ([#894](https://git.alc.xyz/alcxyz/nix-config/issues/894)).
**History:** [replaced text](archive/0083-podman-cleanup-completion-fence-history.md)

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
bulk image prune or cache-mount cleanup. Exited and dead containers outside
pods follow the same rule: capped, sequential deletion by ID with
`force=false`, never a bulk container prune. They go newest first, so a
container's standalone dependents go before it; a container that a pod member
depends on is refused and keeps the fence, as the bulk prune did. A bulk
prune's runtime grows with the number of containers it removes, so any client
deadline can turn a completing prune into an uncertain one. Retain existing
request and service budgets, lifecycle exclusion and terminal-job checks. A
pass may do partial work within its budget.

Cleanup starts, and dispatches each destructive request, only while the host's
full I/O stall (`full avg10` in `/proc/pressure/io`) is at or below the aggregate
pressure guard's resume threshold (`ioPressureGuard.lowPercent`, 5 percent by
default), so it runs only when the guard itself would consider the host
recovered. Cleanup windows occur mostly during guard drains, often pressure
drains, when an API request is most likely to time out and retain the
completion fence. A sample above the threshold before the lifecycle lock
and any API request is a normal `io_pressure` skip that creates no fence; an
unreadable or malformed sample is uncertain and also skips
(`io_pressure_unreadable`). The sample is read again before each destructive
request: a high or unreadable sample ends the pass as a normal
`bounded_partial` skip with cause `io_pressure`, before that request's fence
is created. Earlier requests have each already cleared their own fence or
failed with it retained. The check never abandons a dispatched request and
does not change when a fence is cleared. It applies to normal Podman cleanup
and to the manual Docker volume mode.

Cleanup may optionally become eligible below the filesystem-pressure trigger,
so an existing safe idle window can remove old artifacts before the filesystem
fills. The critical free-space floor and every lifecycle and completion check
still apply. This option does not stop runners or create a maintenance window;
the image creation-age cutoff is eligibility, not a deletion deadline or a
measurement of time since last use. It does not impose a runtime-store quota.
That cutoff applies only to images: eligible disposable Buildx builders,
terminal containers and unused Buildx state volumes retain their existing
selection rules and can be removed sooner. More eligible windows also create
more opportunities for an uncertain deletion to retain the completion fence;
recovery remains explicit even when the filesystem has plenty of free space.

Validate the complete compatible and native container snapshots before any
container mutation. Exclude native pod members and infra containers from both
live-leftover/Buildx and exited/dead selection. Order this combined queue by
compatible creation seconds, native fractional seconds, then ID, descending.
`CONTAINER_DELETE_LIMIT` caps the entire ordered prefix at at most eight
attempts, including live leftovers and Buildx builders, rather than only exited
containers. Never skip a capped candidate to remove an older candidate.
Preserve each kind's existing deletion flags and response validation. A cap or
budget that leaves safe live leftovers reports a normal `bounded_partial` skip;
terminal checks still precede builder-volume and image cleanup. Creation order
is a heuristic, not dependency discovery: skipped dependents and clock changes
can still cause refusals, and uncertain responses retain the fence.

Manual Docker volume cleanup is a separate opt-in mode, selected only by a
nonempty `DOCKER_VOLUME_MANIFEST` path. The default remains normal Podman
cleanup, with its existing limits. The manifest is a regular, non-symlink,
single-link file owned by the executing UID (root in the installed service),
mode `0600`, with the exact schema
`{"volumes":[{"name":"fixture_volume","created_at":"2026-01-01T00:00:00Z"}]}`.
Validate the complete manifest before mutation: reject unknown keys, duplicate
names, unsafe names and malformed creation timestamps. This is a manually
reviewed identity allowlist, not a naming-prefix or automatic retention policy.

Both engine inventories must be completely validated and fully terminal before
any mutation in this mode; Podman leftovers are not eligible. Preserve every
volume referenced by any Docker container, including stopped containers.
Inspect each candidate through the dedicated Docker socket and require exact
`Name` and `CreatedAt` equality, `local` driver and scope, and empty options
(null or an empty object). An inspect 404 may report absence. Delete only the
exact `/volumes/<name>?force=false` endpoint, never bulk prune, force deletion
or raw directory removal. This mode makes no Podman mutations.

Allow at most two sequential per-name DELETE attempts per pass. Each request
has a maximum 25-second client deadline and must fit its remaining lock budget;
read-only requests also check their remaining budget. Keep the existing
40-second lock budget and 60-second service bound. A cap or insufficient budget
for the next request is a normal `bounded_partial` result. `PRESSURE_ONLY=0`
may bypass the ordinary pressure trigger, but never the critical capacity
floors, the I/O pressure precondition, lifecycle preflight, exact configured
runner registry, all-runner terminal inactivity, healthy unfrozen aggregate or
both API execution-generation checks. A client deadline does not cancel server-side deletion. Real Docker
qualification remains required before operational use.

Before each destructive request, create an independently owned, trusted runtime
completion fence under the lifecycle lock. Clear it only on a validated complete
acknowledgement belonging to that request. Timeout, disconnect, helper death,
partial responses and uncertain errors leave it intact. Existing or malformed
fences block further cleanup, every runner start gate, guard resume and both
dedicated API starts even after the lock is released. API admission uses fixed
root-executed conditions under the shared lifecycle lock. Docker's condition
checks only the cleanup fence, retaining ordinary Docker-only boot ordering;
Podman's existing registry and controller checks remain in force. The guard remains healthy; freeze,
thaw, teardown and manually stopped runner ownership remain independent.

Normal Podman requests retain the `cleanup-v2 <pid> <bashpid> <nonce> <method>
<path>` owner format and its compatible recovery parser. Manual Docker volume
requests use the explicit `cleanup-v3 <pid> <bashpid> <nonce> docker DELETE
/volumes/<name>?force=false` format. V3 recovery accepts only that exact engine,
method and safe path. Clear a Docker request's own fence only after a validated
204 with an empty body and no nonempty body framing, or a Docker 409 JSON
object with a nonempty `message` refusal. Any other dispatched status (including 404), timeout, disconnect,
500 or malformed response retains the fence and stops further requests.
V3 also records response headers as a known fence file for acknowledgement
validation and recovery. V2 Podman acknowledgements retain their existing
validation rules.

Record both API execution generations before mutation. Do not infer recovery
from elapsed time, attempts, read-only API success or PID changes. An explicit
operator-invoked recovery command verifies trusted fence ownership and format,
the exact runner registry against the runner list built into the command,
terminal API generation evidence, and fully terminal runners and APIs without
main/control processes or pending jobs. It requires positive
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
recovery or reboot. The I/O pressure precondition gives up cleanup windows
during pressure drains to make uncertain requests less likely; under sustained
I/O pressure, cleanup waits until the host is back at or below the guard's
resume threshold. Individual deletes avoid unfiltered cache-mount cleanup and
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
