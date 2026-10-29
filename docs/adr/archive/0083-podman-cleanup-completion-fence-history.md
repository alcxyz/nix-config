**History of** [ADR-0083](../0083-podman-cleanup-completion-fence.md): text replaced on 2026-10-29.

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
