**History of** [ADR-0083](../0083-podman-cleanup-completion-fence.md): text replaced on 2026-10-29 and 2026-10-30.

# ADR-0083: Fence admission until Podman cleanup completion is known

## Text replaced on 2026-10-29

From the decision, before the I/O pressure precondition
([#894](https://git.alc.xyz/alcxyz/nix-config/issues/894)):

Allow at most two sequential per-name DELETE attempts per pass. Each request
has a maximum 25-second client deadline and must fit its remaining lock budget;
read-only requests also check their remaining budget. Keep the existing
40-second lock budget and 60-second service bound. A cap or insufficient budget
for the next request is a normal `bounded_partial` result. `PRESSURE_ONLY=0`
may bypass the ordinary pressure trigger, but never the critical capacity
floors, lifecycle preflight, exact configured runner registry, all-runner
terminal inactivity, healthy unfrozen aggregate or both API execution-generation
checks. A client deadline does not cancel server-side deletion. Real Docker
qualification remains required before operational use.

## Text replaced on 2026-10-30

Before automatic recovery of settled Podman cleanup fences
([#914](https://git.alc.xyz/alcxyz/nix-config/issues/914)).

From the decision:

> more opportunities for an uncertain deletion to retain the completion fence;
> recovery remains explicit even when the filesystem has plenty of free space.

> Record both API execution generations before mutation. Do not infer recovery
> from elapsed time, attempts, read-only API success or PID changes. An explicit
> operator-invoked recovery command verifies trusted fence ownership and format,

> freeze, drain and teardown ownership. The command never stops, starts or resets
> units and provides no automatic recovery. Reboot clears runtime state.
> Operational qualification and recovery procedures remain private.

From the alternatives:

> - Longer client deadlines or presumed request cancellation do not establish
>   storage completion and increase the blocked admission interval.

From the consequences:

> Bounded cleanup no longer silently reopens admission while storage work may
> continue. Ambiguous completion deliberately costs CI availability until positive
> recovery or reboot.
