# CI runner labels

Forgejo Actions runners for the alcxyz repositories are configured in
[`hosts/`](../hosts) through the
[runner module](../modules/nixos/services/forgejo-actions-runner/default.nix).
[ADR-0097](adr/0097-ci-fast-runner-label.md) records the label design.

## Labels

| Label | Served by | Use for |
|-------|-----------|---------|
| `forgejo-podman` | xyz, xev, nex, nux | The default shared pool for container jobs. |
| `ci-fast` | xyz and xev (a dedicated runner each; xyz's pool runner takes overflow) | Heavy jobs on a project you are iterating on. Never runs on nex or nux; the job waits instead. |
| `forgejo-podman-canary` | xyz, xev, nex, nux | Existing Nix and platform validation workflows. |
| `ubuntu-latest`, `forgejo-docker-primary` | the Docker runners on xyz, xev, nex and nux | Older workflows; prefer `forgejo-podman` for new ones. |

Jobs on xyz yield to desktop work and stop being admitted while a game runs,
whatever their label.

## Fast CI switch

Write heavy jobs, such as end-to-end suites, so that a repository variable can
send them to the fast hosts:

```yaml
jobs:
  e2e:
    runs-on: ${{ vars.CI_FAST == 'true' && 'ci-fast' || 'forgejo-podman' }}
```

Leave light jobs on `forgejo-podman`. With the variable unset, the job uses the
shared pool as before.

`ci-fast` jobs run on a dedicated one-slot runner on xyz (`xyz-fast`) or on
xev (`xev-fast`), or on a free slot of xyz's pool runner, which also serves
`ci-fast`. Whichever runner polls first takes the job, so a fast job may land
on xev or take xyz's pool slot while `xyz-fast` is idle. A fast job never
waits while any of these slots is free, and the dedicated slots mean it does
not have to wait for shared-pool jobs.

While a game runs on xyz, or xyz is off, its runners take no jobs and
`xev-fast` serves fast jobs alone.

To turn fast CI on for a repository while you iterate, create the Actions
variable `CI_FAST` with the value `true` under the repository's Settings >
Actions > Variables, or:

```sh
tea api -X POST /repos/alcxyz/<repo>/actions/variables/CI_FAST -f value=true
```

Delete the variable when you are done, so that turning it on again is the same
create step:

```sh
tea api -X DELETE /repos/alcxyz/<repo>/actions/variables/CI_FAST
```

The value is read when a run is created, so it affects new runs only.
