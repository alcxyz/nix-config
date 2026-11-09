# CI runner labels

Forgejo Actions runners for the alcxyz repositories are configured in
[`hosts/`](../hosts) through the
[runner module](../modules/nixos/services/forgejo-actions-runner/default.nix).
[ADR-0097](adr/0097-ci-fast-runner-label.md) records the label design.

## Labels

| Label | Served by | Use for |
|-------|-----------|---------|
| `forgejo-podman` | xyz, xev, nex, nux | The default shared pool for container jobs. |
| `ci-fast` | xyz and xev (their pool runners, in the same slots as `forgejo-podman`) | Heavy jobs on a project you are iterating on. Never runs on nex or nux; the job waits instead. |
| `forgejo-podman-large` | xyz only (its pool runner, in the same slot as `forgejo-podman`) | Jobs whose throwaway data exceeds the other hosts' 8G RAM scratch, up to xyz's 16G, such as the nix-packages Nix update jobs ([ADR-0108](adr/0108-ram-scratch-for-podman-ci-jobs.md)). Waits while xyz is held for a game or off. |
| `forgejo-docker` | the Docker runners on xyz, xev, nex and nux | Jobs that need the Docker engine rather than Podman. Prefer `forgejo-podman`. |

No other labels exist. The Docker aliases `forgejo-docker-primary`,
`forgejo-docker-secondary`, `ubuntu-latest` and `docker`, the host-name labels
and the Podman canary labels were retired
([#957](https://git.alc.xyz/alcxyz/nix-config/issues/957)); a job that asks for
one waits forever, since Forgejo has no label fallback.

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

`ci-fast` jobs run on the pool runners of xyz and xev (one slot each),
which serve `forgejo-podman` jobs in the same slots. Whichever runner polls
first takes the job, so a fast job may land on xev while xyz is free. A fast
job never waits while one of these slots is free, but it waits while both
are busy, shared-pool jobs included. Most jobs take about 2 minutes, so
a slot frees quickly.

While a game runs on xyz, or xyz is off, its runners take no jobs and xev
serves fast jobs alone.

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

## Host Nix store (trial on xyz)

Pool hosts with `podmanCanary.nixCache` keep a read-only Nix store of
cache.nixos.org paths and pinned GitHub, GitLab and SourceHut flake inputs
([ADR-0109](adr/0109-shared-read-only-nix-store-for-podman-ci-jobs.md)). A
Nix job opts in by mounting it as the lower layer of its `/nix/store`, so
cached paths are neither downloaded nor written again; new paths go to the
job's RAM scratch. The store is shown ID-mapped, owned by the job's root, so
a path the job's database does not list is simply substituted again into its
scratch. Hosts without it drop the mounts, and the job installs Nix as
before, which also works on top of the store:

```yaml
jobs:
  nix:
    runs-on: forgejo-podman
    container:
      image: docker.io/library/node:20-bookworm
      options: >-
        -v /run/forgejo-nix-cache/nix/store:/nix/store:O
        -v /run/forgejo-nix-cache/job:/nix-cache:ro
        -v /run/forgejo-nix-cache-drop:/nix-cache-drop
    steps:
      - name: Use the host's Nix store
        id: nix-cache
        if: forgejo.event.pull_request.head.repo.fork != true
        run: |
          if [ -x /nix-cache/nix/bin/nix ] && [ -s /nix-cache/db/db.sqlite ]; then
            mkdir -p /nix/var/nix/db /etc/nix
            cp /nix-cache/db/db.sqlite /nix-cache/db/schema /nix/var/nix/db/
            printf '%s\n' 'build-users-group =' 'experimental-features = nix-command flakes' 'sandbox = false' > /etc/nix/nix.conf
            echo /nix-cache/nix/bin >> "$GITHUB_PATH"
            /nix-cache/nix/bin/nix path-info --all | sort > /tmp/nix-paths-before
            echo used=true >> "$GITHUB_OUTPUT"
          fi
      - uses: https://github.com/cachix/install-nix-action@v30
        if: steps.nix-cache.outputs.used != 'true'
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
            sandbox = false
      # ... the job's Nix steps ...
      - name: Offer the paths this run used to the host's store
        if: >-
          always() && steps.nix-cache.outputs.used == 'true' && (
            (forgejo.event_name == 'push'
              && forgejo.ref == format('refs/heads/{0}', forgejo.event.repository.default_branch))
            || (forgejo.event_name == 'pull_request'
              && forgejo.event.pull_request.head.repo.full_name == forgejo.repository))
        run: |
          name="$(printf '%s' "$GITHUB_REPOSITORY" | tr '/' '_')-$GITHUB_RUN_ID-$GITHUB_JOB"
          # Built in the job's own /tmp, then copied under a dot name the
          # filler ignores and renamed at once, so the filler never reads a
          # half-written list and the sweep never meets a long-lived one.
          nix path-info --all | sort | comm -13 /tmp/nix-paths-before - |
            xargs -r nix-store -qR --include-outputs | sort -u > /tmp/nix-offer.paths &&
            cp /tmp/nix-offer.paths "/nix-cache-drop/.$name.paths" &&
            mv "/nix-cache-drop/.$name.paths" "/nix-cache-drop/$name.paths" || true
          cp flake.lock "/nix-cache-drop/.$name.lock" &&
            mv "/nix-cache-drop/.$name.lock" "/nix-cache-drop/$name.lock" || true
```

The steps use POSIX shell only: act runs container steps with `sh`.

Pushes to the default branch and pull requests from the repository's own
branches offer lists; fork pull requests neither use the store nor offer.

The list holds the paths the run added and everything they reference,
including the outputs of the derivations it instantiated that are already in
the store. The filler roots the listed paths it already has again, which
renews their age without fetching them, and substitutes the missing ones. It
admits only what cache.nixos.org signed, and `github`, `gitlab` and
`sourcehut` inputs pinned to a commit whose hash it verified; other paths
and inputs (tarballs, git URLs, host overrides, submodules) are skipped, and
jobs fetch those themselves. Lists are not private between jobs, which all
run as one host user, so they must hold nothing but store paths and lock
files. While a job runs, the filler only renews what it already has. A job's complete
`nix path-info --all` would also name the whole lower store, so every run
would renew every path and nothing would ever expire by age.
