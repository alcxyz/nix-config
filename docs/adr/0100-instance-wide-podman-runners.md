# ADR-0100: Register the Podman runners instance-wide

**Status:** Accepted
**Date:** 2026-10-20
**Applies to:** `modules/nixos/services/forgejo-actions-runner/`, the Forgejo
runner registrations of xyz, xev, nex and nux

## Context

Every Forgejo runner on xyz, xev, nex and nux was registered to the `alcxyz`
user. Forgejo hands a user's runners only jobs from that user's repositories.
Repositories are moving into organisations such as `funhouse-xyz`, and jobs
there found no runner and waited until Forgejo abandoned them.

A runner registers to exactly one scope: the instance, one user or
organisation, or one repository. Each registration is its own daemon with its
own job slots.

## Decision

- The Podman runners (ADR-0074, ADR-0097) register instance-wide, so they take
  jobs from every repository on the instance: the `alcxyz` user's and every
  organisation's, present and future. Each host keeps its Podman pool runner,
  plus the `ci-fast` runners of ADR-0097, and every owner can use all four
  hosts.
- The Docker runners keep their per-owner registration; this decision covers
  only the Podman runners. The private flake records the trust boundary and
  the registration tokens.
- `podmanCanary.registrationScope` (and each extra runner's, which follows the
  canary's) records the scope of the registration token. The registration
  helper records it beside the runner name and registers anew when it
  changes. The default, `owner`, passes no scope, so existing registrations
  are kept until a host opts in.

## Alternatives Considered

- **A registration per organisation on every host.** Needs one daemon per host
  per organisation. Each daemon has its own job slots, so concurrent jobs from
  several owners oversubscribe a host's build budget, and every new
  organisation adds units on every host.
- **One organisation-registered runner on one host.** Simplest, but leaves the
  organisation's jobs on a single host.
- **Detect the scope change from the token file.** Recording a token's hash
  keeps secret-derived state on disk, and a changed file path says nothing
  about the token's scope. An explicit setting states the intent.

## Consequences

- The scope and the token change together, in one deploy. A runner that
  registers with the old token under the new scope records the new scope and
  is not registered again.
- Podman runner units set `restartIfChanged = false`, and registration runs
  when a unit starts. A switch therefore changes nothing until each Podman
  runner is restarted while idle, or its host reboots; it then registers anew
  under its existing name.
- The old registrations stay listed. Delete them only after the new ones show
  up, since a running runner still uses its old registration.
- Limiting slower hosts to small jobs stays a matter of labels and capacity
  (ADR-0097) and is independent of the registration scope.
