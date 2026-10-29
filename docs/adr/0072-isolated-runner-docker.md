# ADR-0072: Isolate runner Docker execution in a bounded rootless service

**Status:** Accepted
**Date:** 2026-09-10
**Amended:** 2026-10-28; 2026-10-29, a read-only hold monitor reports runner admission held beyond a bound ([#894](https://git.alc.xyz/alcxyz/nix-config/issues/894))
**History:** [replaced text](archive/0072-isolated-runner-docker-history.md)
**Area:** Forgejo runners, Docker, systemd

## Context

Runner-applied container options and labels do not reach Docker and BuildKit
workers created through a mounted daemon socket. Limits must cover daemon-side
execution as well as outer job containers, without changing application Docker.

## Decision

The optional dedicated-daemon retention policy configures native BuildKit GC
with a 20 GiB unused-cache target and prefers cache unused for 48 hours. It also
runs dedicated Docker system pruning daily for currently unused images and
stopped containers created at least 48 hours ago. Volumes remain outside that
prune. It also prunes eligible unused networks and build cache, independently
of native GC, and may reduce cache below the target. This is not a filesystem
quota: active builds, images and protected
references can retain more data. Separate `docker-container` BuildKit workers
need their own GC settings and disposable-builder cleanup; daemon GC does not
manage their cache volumes. Application Docker retention remains separate.

A separate, manual exact-allowlist exception may remove disposable volumes
through the dedicated Docker socket, under the lifecycle and completion fence
contract in [ADR-0083](0083-podman-cleanup-completion-fence.md). It does not
enable automatic volume sweeping or change retention defaults.

The option stays disabled by default. Fleet hosts explicitly opt in, and the
runner-pool check verifies their shared settings. Changing daemon GC settings
requires a controlled application to the running daemon; switching a unit with
`restartIfChanged = false` alone does not establish runtime activation.

Use a dedicated rootless Docker daemon in a delegated systemd service below the
existing aggregate build slice. Its daemon and worker descendants inherit the
slice's CPU/memory budget. The runner connects only to that daemon and loses its
host Docker group membership. The daemon owns separate runtime state, images,
volumes and build cache. User-namespace networking leaves host Docker separate.

The pressure controller stays outside the build slice and, by default, freezes
the complete aggregate under sustained pressure. It thaws only a freeze it
owns; uncertain operations fail closed for reconciliation. A slice thaw does
not issue Docker unpause calls, so individually paused containers remain
paused.

An opt-in root-filesystem free-space signal uses the same controller and
ownership state for isolated runners. Falling below either the byte or percent
admission floor gracefully drains every runner; falling below either critical
floor freezes the aggregate to stop active worker writes. Resuming admission
requires both byte and percent headroom to remain above their recovery floors
for the normal low-pressure interval. Thawing an owned freeze requires only low
pressure and space above the critical floors: a frozen daemon cannot run the
cleanup that would restore headroom, so waiting for recovery would hold the
freeze indefinitely. The runner start gate checks space independently
so boot and configuration switches cannot bypass a drain. An unreadable or
invalid sample fails closed. This sampled guard is an emergency circuit breaker,
not a hard storage quota: writes may consume the remaining space between samples
or before a freeze completes. Cache cleanup and operator recovery remain needed
when the filesystem is critically full.

Isolated runners may separately opt into pressure-based admission draining.
Moderate sustained pressure requests a non-blocking stop of only the runner
service: Forgejo Runner stops polling, then waits for already admitted jobs up
to its normal job timeout while the dedicated Docker daemon and workers remain
available. Sustained severe pressure still freezes the complete aggregate.
Recovery thaws an owned freeze before it restarts a runner it previously
drained, and only after pressure stays low and the runner is fully inactive.
The graceful service stop signals the runner's main process first and retains
the existing service timeout as the eventual whole-cgroup termination boundary.

A drain must not outlast its cause (#646). Host-wide PSI
does not attribute pressure: unrelated load that stays between the resume and
drain thresholds once held both runners drained for hours with no CI job
running. Owned drains therefore also resume after a longer settled interval
(5 minutes by default) in which host pressure stays below the drain threshold
and the aggregate's own full I/O PSI stays at or below the resume threshold.
Buffered ZFS writeback from CI is not charged to the aggregate, so its PSI is
only a weak hint; the interval therefore counts only once every drained runner
has finished its admitted jobs, and work they leave behind must also settle.
The faster low-pressure path is unchanged, and the drain rule still uses
host-wide pressure. Sustained load at or above the drain threshold still
withholds admission. The settled path never applies while the guard owns a
freeze, since frozen workers report no stall time; owned thaw keeps its
existing rule. An unreadable aggregate sample disables only the settled path.

A held runner must also be announced, whatever held it (#894). A manual
maintenance stop once kept xyz's runners off for about 41 hours, and a cleanup
completion fence ([ADR-0083](0083-podman-cleanup-completion-fence.md)) once
withheld a resume for about 80 minutes; neither told anyone. A read-only hold
monitor therefore checks every runner unit on each runner host every 5 minutes.
A runner that has not been active for longer than a bound (30 minutes by
default) is reported to Healthchecks as a failure naming the unit, how long it
has been held, its systemd state, the guard markers present (drain, resume,
disk, game skip, standby, cleanup fence, freeze or teardown) and the guard's
state. A unit stopped, disabled or masked outside the guard counts as held.
A detected game, shown by a recent guard game record, and a standby runner its
controller has not admitted ([ADR-0097](0097-ci-fast-runner-label.md)) are
intended holds: they are not reported and restart the count, but never excuse a
disabled or masked unit. Otherwise each run pings success. The monitor only
queries systemd and reads the guard's state, which systemd mounts read-only
for it; it keeps hold start times in its own runtime directory, so a reboot
restarts the count. It reuses the host storage monitor's private ping base
with a `ci-runners-<host>` check, and an unreadable ping base fails the unit.
The guard itself still logs one `admission_drain_prolonged` event for a drain
held beyond the same default bound without a detected game, naming the cause
that claimed it, or `unknown` for a drain restored after a guard restart.

An optional game-process signal can request the same admission drain before
resource pressure rises. Match configured game executable names for a configured
local user. Wine games may rename their Linux process; verify the Wine loader
first, then inspect only the first executable argument, never other arguments
or process environments. Do not infer gaming from launcher presence alone.
The existing guard samples this signal, avoiding a second controller with
independent stop/resume ownership. A matching game or an
unavailable detector withholds admission. Resumption requires the game to be
absent for a short cooldown and the existing pressure recovery conditions.
The runner start gate also checks the signal so boot and configuration switches
cannot admit work before the guard's next sample. Detector errors withhold new
work rather than terminating the running worker APIs. Existing jobs drain
gracefully; this policy does not promise immediate resource release when a game
starts. Severe-pressure freeze/thaw and safe shutdown remain independent.
An explicit root-only game bypass can temporarily admit runners while a game is
detected. It may remain on until switched off or expire after a chosen uptime
duration; reboot clears either mode. Invalid bypass state fails closed. The
bypass affects only the game signal: pressure drains, severe-pressure freezes,
and safe shutdown retain their normal behavior. Broader game detection is tracked
in [#459](https://git.alc.xyz/alcxyz/nix-config/issues/459).

Drain and resume ownership is persistent and transition intent is recorded
before systemd is called. A restarted guard continues an owned drain without a
second stop request. Ownership is bound to the runner execution generation; a
changed generation is disowned and fails closed. Ambiguous transitions fail
closed, and inactive, disabled, masked, or failed runners that the guard did not
safely claim are never started. Admission draining is disabled by default and
is valid only with isolated Docker, because shared-daemon runners do not provide
the same worker-lifecycle boundary. Manual lifecycle intervention during an
owned drain must disable or mask the runner before stopping it so automatic
recovery cannot undo the intervention.

Start the guard after the resource slice and before the daemon. The daemon binds
to guard health, so losing the controller stops existing worker descendants as
well as new runner dispatch. Recovery must explicitly restore daemon/runner
service after a controller failure; it must not silently resume interrupted jobs.

An external lifecycle service starts after the dedicated daemon and before any
runner or cache consumer. Its reverse stop ordering lets it run before daemon
teardown when the guard fails or the system shuts down. If the guard is lost or
the aggregate is frozen, it terminates only the validated aggregate cgroup
through `cgroup.kill` and verifies that no descendants remain. It then thaws a
freeze with unambiguous guard ownership so systemd can finish stopping the
daemon. Manual or pending freezes remain frozen; admission drain ownership is
independent of freeze ownership. An ordinary unfrozen daemon stop remains
graceful. A teardown marker blocks controller reentry until explicit recovery.
The guard defers pressure transitions until the lifecycle service is active,
while bounded start checks prevent consumers from entering before that service.
Consumers do not order their stop before lifecycle teardown: a runner waiting
for a frozen worker can otherwise delay shutdown for its full job timeout.
After aggregate workers are gone, destructive teardown terminates any runner
still waiting for those jobs.
For the isolated aggregate, the slice omits systemd's default shutdown stop
dependency. Otherwise shutdown queues the slice's stop job before lifecycle
teardown runs, and systemd rejects an owned thaw with a pending-job error even
after all workers have exited. The lifecycle service retains its normal
shutdown ordering and still kills and verifies aggregate descendants before an
owned thaw. The empty slice remains for final system teardown rather than
being stopped through a conflicting freezer job.

Guard and daemon failures do not auto-restart. Configuration switches do not
restart the isolated runner, daemon, guard, lifecycle service or resource-policy
service when their units change. New unit definitions take effect during a
planned restart or reboot, after drain and freeze ownership has been resolved.
NixOS may also start an inactive unit wanted by an active target during a
switch. The runner therefore has a privileged, fixed `ExecCondition` that
checks guard ownership under the same lock as drain and resume transitions.
It skips starts while drain, freeze or teardown state is pending or owned;
the guard's completed resume request clears its pending marker before the
condition can acquire the lock. A skipped start is not an automatic restart
failure and leaves ownership markers unchanged.

A resume is owned until the runner is active, not only until its start is
queued (#844). A unit condition, such as a temporary
runtime hold, or the start gate can skip the queued start, and the guard once
forgot the runner as soon as the request was accepted, leaving it stopped for
hours after the hold cleared. The guard therefore records the unit's condition
timestamp with the queued resume. Systemd moves that timestamp for every start
it processes, so the guard can tell a start that is still queued from one that
ran, was skipped, or was cancelled or refused before its conditions ran. An active runner ends
ownership. A skip that left a gate hold marker (disk, game or standby) passes
ownership to that marker's owner. Any other skip is reported once and the
start is requested again, with spacing that doubles up to a bound (5 minutes by
default), only while a resume would be allowed: recovery and game conditions
hold, no cleanup fence or owned freeze is present, and the unit is still
loaded and enabled. Each retry is a new start that systemd's conditions and
the start gate evaluate again, so no gate is bypassed. A start that ran and
then stopped or failed, or that never reached its conditions, ends ownership
with a report and is never retried. A disabled or masked runner is reported
and not started, so disabling or masking it still keeps it off.

The guard retries read-only systemd metadata queries for a bounded interval
during daemon reloads. A stop or start request whose outcome may be ambiguous
is never retried; only a start that systemd confirms it skipped is requested
again. A persistent metadata failure still stops the guard
and invokes the destructive controller-loss boundary.

All runner clients, mounted sockets and cache maintenance use the dedicated
endpoint. The module stays disabled by default; enable each host after runtime
qualification. xyz, nex, nux and xev run it, each enabled after its
qualification between 2026-09-10 and 2026-09-12 (#345), and all four opt into
the retention policy.
The daemon gives containers a 65,536 default open-file limit and has a separate
1,048,576 service limit. Docker's embedded build executor can inherit the daemon
limit instead of the container default. These bounds keep inherited host limits
from making portable descriptor cleanup paths unreasonably expensive.

The system service owns the aggregate boundary. Rootless Docker may report no
per-container cgroup support without a user service manager; those individual
limits are not the contract. Qualification must prove ancestor limits remain
effective for ordinary builds and buildx workers, including cgroup overrides.
Use a dedicated unprivileged account and the kernel overlay driver; do not
silently fall back to host Docker on incompatibility. A userspace FUSE storage
provider inside the frozen aggregate can stop before a client blocked on that
provider reaches the frozen state, so it is incompatible with this aggregate
freeze contract.

Keep the kernel-overlay data root separate from an earlier FUSE candidate. The
old candidate remains disposable rollback data under the same bounded dataset;
do not reinterpret or migrate its storage-driver-specific state.

## Alternatives

A second rootful daemon with a default cgroup parent keeps existing behavior,
but the API can override that parent and its network setup still modifies host
firewall state. It does not by itself establish the required boundary.

Adding labels and resource flags to each workflow misses daemon-internal builds
and relies on every nested invocation remembering the convention.

A rootless user service can support per-container systemd cgroups, but adds a
user manager lifecycle and changes the aggregate placement model. Revisit this
if existing workflow compatibility requires those controls.

Stopping the guard before the daemon through its own stop hook cannot resolve a
frozen daemon: startup ordering reverses during shutdown, so the daemon's stop
job would wait before that hook could run. Thawing before terminating workers
would permit interrupted jobs to resume. Restarting changed units during a
configuration switch could also start a runner that was deliberately drained.

## Qualification and consequences

The disposable fixture `flake/checks/forgejo-isolated-docker-vm.nix` passes daemon
startup, runner-user socket access, ordinary container and nested Docker-build
worker ancestry, cgroup override containment, the 50% aggregate CPU ceiling,
40% memory throttling and the 50% hard memory ceiling. The memory fixture raises
only its soft threshold to reach the unchanged hard limit promptly and selects
a disposable allocator as the OOM victim. `OOMPolicy=continue` prevents systemd
from stopping the entire daemon service after a descendant is killed; it does
not guarantee which process the kernel selects under production pressure.
Aggregate freeze/thaw and worker teardown after killing the guard also pass.
Host Docker remains responsive during the freeze. It uses a locally built
dummy image and never registers a runner. Run it explicitly with:

```sh
nix-build --no-out-link --impure --max-jobs 1 --cores 2 \
  --expr 'let pkgs = import (builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath {}; in import ./flake/checks/forgejo-isolated-docker-vm.nix { inherit pkgs; }'
```

The fixture also exercises guard loss while workers are frozen, preservation of
a manual freeze, a configuration switch with an intentionally drained runner
wanted by an active target, and shutdown with a runner waiting on a frozen
worker. Separate shutdown boots verify that a manual freeze and an owned
freeze with a pending transition marker are not thawed, while lifecycle
teardown completes without a frozen-unit stop error.

The positive fixture `flake/checks/forgejo-isolated-docker-paths-vm.nix` uses the
real local Forgejo executor without registration or external image pulls. It
verifies job, service, Docker action, nested container and buildx-container
ancestry, including an actual BuildKit RUN worker. Job and action socket mounts
point at the dedicated daemon. Under injected pressure, nested-container CPU
progress and BuildKit worker progress stop, then resume on owned recovery;
a host application keeps progressing and a manually paused host container stays
paused. The long-running fixture workloads are explicitly terminated at cleanup;
this is not a successful end-to-end workflow completion test.

The initial local-executor fixture omitted `--container-daemon-socket` and mounted
the host socket despite selecting the dedicated API endpoint. That was a fixture
routing error. Daemon mode obtains its mounted path from `container.docker_host`.
The corrected test checks both the actual mount source and API access.

[Docker documents](https://docs.docker.com/engine/security/rootless/tips/)
system-wide rootless services as unsupported. Deployment therefore requires the
bounded backing-filesystem canary and real hosted workflows to pass per host. The fixture
preserves host-Docker manual pauses; it does not establish per-container pause
support inside the rootless daemon without per-container cgroups.

Nix evaluation and synthetic guard tests are necessary but insufficient. A
runtime canary must demonstrate job, step, service, Docker build and buildx
containment; pressure-induced loss of worker progress; owned recovery; preserved
manual pauses; and unaffected application Docker. Keep migration and recovery
procedures in the private operational repository.

Freeze and thaw transitions use a separate 120-second deadline while read-only
metadata queries have a shared bounded retry period during daemon reloads.
The systemctl D-Bus method timeout uses the
remaining transition budget too, so its shorter default cannot cut a valid
transition short. Kernel-backed storage synchronization can make
a valid freezer transition take longer than a routine control query. Ownership
remains pending until systemd reports that the transition completed, so a real
timeout still fails closed for operator reconciliation.
If systemd aborts a freeze while new work is attaching, retry only when the
aggregate is unequivocally running and only within the original transition
deadline. Any other state keeps the pending ownership record and fails closed.

A cold daemon needs additional storage and pulls. I/O weight and cgroup freezing
do not guarantee immediate relief from already queued buffered writes, nor do
they enforce filesystem capacity. Qualify pressure behavior on the actual
backing filesystem. Shared-job credential isolation remains separate work.

The per-host rollout was tracked in
[#345](https://git.alc.xyz/alcxyz/nix-config/issues/345), closed on 2026-09-12
once all four runner hosts were qualified and enabled. Do not enable a further
host on the strength of synthetic tests alone.
