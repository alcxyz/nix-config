# ADR-0074: Qualify Podman through staged Docker coexistence

**Status:** Accepted; Docker stays beside Podman, and no Docker engine is qualified for retirement
**Date:** 2026-09-23
**Amended:** 2026-10-31, both runtimes share the runner hold of [ADR-0106](0106-runner-hold-for-games-and-low-disk.md) instead of a pressure controller and teardown boundary
**History:** [replaced text](archive/0074-phased-podman-coexistence-history.md)
**Area:** host container runtimes, development and CI

## Decision

Podman runs alongside Docker on xyz, xev, nex and nux. Docker's command, API
endpoints, data and existing workloads stay intact. Global Docker
compatibility aliases are not enabled and Docker's socket is not replaced.
Docker-compatible CLI syntax run against Podman is not a Docker engine
dependency.

### CI

Podman CI uses a separate opt-in runner module (`podmanCanary`), enabled on
xyz, xev, nex and nux. Each host's pool runner serves the shared
`forgejo-podman` pool label and keeps the `forgejo-podman-canary` label, which
the manual `Podman canary` workflow and this repository's workflows select.
The extra `xyz-fast` and `xev-fast` runners carry only `ci-fast`
([ADR-0097](0097-ci-fast-runner-label.md)). Routine
validation and the selected image-build workflows moved to Podman after
hosted qualification ([#436](https://git.alc.xyz/alcxyz/nix-config/issues/436),
[#464](https://git.alc.xyz/alcxyz/nix-config/issues/464)); every workflow in
this repository now selects the Podman label, and #464 deliberately left
privileged updater and live-write workflows in other repositories on Docker.
Before another workflow moves, validate its actual job, service, action and
nested build paths. The resource and lifecycle requirements of ADR-0072
remain in force; this decision does not
replace that implementation or authorize weaker limits.

The opt-in CI module uses separate runner identities, an account, API socket
and storage root for Podman. A host may run any number of Podman runner
identities, each its own unit with its own registration and state, against
that one Podman API ([#680](https://git.alc.xyz/alcxyz/nix-config/issues/680)).
Both CI runtimes share `forgejobuilds.slice` and one runner hold
([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), retaining the
existing combined CPU and memory budget. The hold marks each runner it stops
on its own, and a manually stopped runner is not marked or restarted. One
budget for both runtimes deliberately couples their CI capacity: separate
full-size budgets would increase the host's maximum CI allocation. The
application Docker daemon remains outside this boundary.

The Docker and Podman runners on every host build the same qualified runner
package, `forgejo-runner-cancellation`, from the shared package input. It
includes a bounded cleanup fix for cancelled Docker actions, whose upstream
cleanup context otherwise prevents container removal on both engines. No
separate pin supplies it.

### Wolf image build placement

The Wolf image publisher keeps its qualified Podman runner and Buildx path.
The Nix derivations that assemble its three deployed build contexts (`wolf`,
`brave-origin` and `zen`) run instead on the trusted `xyz` operator's
persistent Nix store. A local timer fetches the committed development head,
uses the same native build lock and admission condition as other local
promotion work, and skips commits that did not change Wolf image inputs. It
does not process pull request code.

The producer uploads one archive per product to an exact-commit version of a
channel-specific Forgejo generic package. It uploads a checksum and revision
receipt last, then dispatches the existing publisher at that source commit.
Each publisher job downloads only its own archive, checks the receipt, and
requires the checkout to match the dispatched commit in the trusted branch's
history. Registry publication and deployed runtime references stay unchanged.
The local producer is enabled only for `dev`; `main` can use the same
workflow after normal branch promotion.

The producer retains one local Nix GC root per channel. Package cleanup keeps
the newest two versions and versions younger than 24 hours; it removes only
older versions in its own channel namespace. Failed partial versions can be
resumed by matching file checksums and age out under the same policy. No CI
runner receives host store access or a host daemon mount.

### Services, macOS and Docker retirement

Migrate application services individually after their own functional and
lifecycle checks. Stateful trials use independent data copies; only one
runtime may write the production data at a time. Streaming services require
their existing GPU, audio and input acceptance checks. No host service has
been cut over: native services need no migration, and Wolf is an intentional
Docker exception ([#437](https://git.alc.xyz/alcxyz/nix-config/issues/437)).
Evaluate macOS independently; the Mac keeps its current runtime
([#438](https://git.alc.xyz/alcxyz/nix-config/issues/438)).

Retire Docker only on hosts with no remaining consumers. Keeping explicit
Docker exceptions is an acceptable outcome; application, development, macOS
and privileged updater CI consumers in other repositories remain. Image compatibility alone is
insufficient evidence of API, Compose, builder, rootless or device
compatibility, and a snapshot with no running containers does not establish
that an engine has no consumers. No Docker engine is qualified for retirement.
Before one is retired, qualify consumer absence, the disposition of its saved
data and host acceptance, and keep a rollback
([#439](https://git.alc.xyz/alcxyz/nix-config/issues/439)).

## Alternatives

- A fleet-wide replacement makes failures and rollback span unrelated workloads.
- Keeping Docker exclusively avoids migration work but prevents evaluating
  Podman's rootless development workflow against actual requirements.

## Validation and ownership

The opt-in `scripts/checks/check-podman-coexistence.sh` runs on a Linux host as an
ordinary user. It needs Podman, Docker Compose, curl and timeout. It creates
disposable containers, an image, a network, a volume and a temporary API endpoint;
its Compose commands explicitly select that endpoint. It removes its own
resources and retains the shared downloaded base image. It is not an automatic
flake check and does not start or reconfigure production services.

This canary checks build/run, mounts, volume persistence, cgroup settings,
networking, restart and a synthetic two-service Compose stack. The stack checks
service-name DNS, health-gated `depends_on` startup and named-volume persistence
across `down`/`up`; a separate Compose bind check verifies read/write access and
host ownership with an explicit user mapping. Its `userns_mode: keep-id` setting
is Podman-specific fixture configuration, not evidence that unchanged project
Compose files are portable. This representative fixture does not establish
compatibility with every development project. The canary also does not establish
worker containment, stress behavior, host reboot behavior, production-stack
compatibility or streaming acceptance; those are qualified separately.

The separate, opt-in `flake/checks/forgejo-podman-paths-vm.nix` fixture exercises a
synthetic Forgejo local executor against a rootless Podman API beside Docker. Run
it with the repository root flake's actual `inputs.nixpkgs` source, for example:

```sh
nix-build --no-out-link --impure --max-jobs 1 --cores 2 --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs {};
    runnerPackage = pkgs.callPackage
      "${flake.inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
  in import ./flake/checks/forgejo-podman-paths-vm.nix {
    inherit pkgs runnerPackage;
    productionModule = true;
  }'
```

The tested Docker buildx container driver needs a cgroup parent within the
delegated Podman service, `default-load=true` for ordinary tagged `docker build`
output, and `BUILDX_BUILDER` to select that builder for `docker build`. This VM
does not qualify hosted workflows or registry pushes. The invocation above
selects the production module and qualified runner; the fixture also supports
a minimal standalone runtime. It remains outside standard flake checks.

The executor-path fixture accepts `productionModule = true` to exercise the
same paths against the opt-in module, and `runnerPackage` to select the
qualified runner. It verifies graceful cancellation removes native job, service
and action containers while the API remains available. Caller-created nested
containers and builders are checked separately. The flake check
`forgejo-runner-hold-lifecycle` (`flake/checks/forgejo-runner-hold-vm.nix`)
runs the Docker runner and two Podman runners beside both engines through the
runner hold. The executor-path fixtures are explicit qualification runs, not
automatic host activation.

Host evidence and recovery procedures belong in the private operational
repository. Deployment manifests remain owned by GitOps; public host interfaces
and generic qualification checks remain here.

The phased adoption was tracked in the
[Podman adoption milestone](https://git.alc.xyz/alcxyz/nix-config/milestone/323)
(issues #433 to #439, all closed by 2026-10-09).
