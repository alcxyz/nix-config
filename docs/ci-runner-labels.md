# CI runner labels

Forgejo Actions runners for the alcxyz repositories are configured in
[`hosts/`](../hosts) through the
[runner module](../modules/nixos/services/forgejo-actions-runner/default.nix).
[ADR-0097](adr/0097-ci-fast-runner-label.md) records the label design.

## Labels

| Label | Served by | Use for |
|-------|-----------|---------|
| `forgejo-podman` | xyz, xev, nex, nux | The default shared pool for container jobs. |
| `ci-fast` | xyz; xev only while xyz is unavailable (planned) | Heavy jobs on a project you are iterating on. Never runs on nex or nux; the job waits instead. |
| `forgejo-podman-canary` | xyz, xev, nex, nux | Existing Nix and platform validation workflows. |
| `ubuntu-latest`, `forgejo-docker-primary` | the Docker runners on every host | Older workflows; prefer `forgejo-podman` for new ones. |

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
