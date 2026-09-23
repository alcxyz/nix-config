# ADR-0074: Qualify Podman through staged Docker coexistence

- Status: Accepted; qualification in progress
- Date: 2026-09-23
- Area: host container runtimes, development and CI

## Decision

Qualify Podman alongside Docker, beginning with disposable rootless development
containers on one Linux host. Keep Docker's command, API endpoints, data and
existing workloads intact. Do not enable global Docker compatibility aliases or
replace its socket during the trial.

CI adoption requires a separate opt-in runner and exclusive canary labels.
Validate actual job, service, action and nested build paths before moving normal
workflows. The resource and lifecycle requirements of ADR-0072 remain in force;
this decision does not replace that implementation or authorize weaker limits.
Controller failure and shutdown qualification precede any production CI cutover.

Migrate application services individually after their own functional and lifecycle
checks. Stateful trials use independent data copies; only one runtime may write
the production data at a time. Streaming services require their existing GPU,
audio and input acceptance checks. Evaluate macOS independently.

Retire Docker only on hosts with no remaining consumers. Keeping explicit Docker
exceptions is an acceptable outcome. Image compatibility alone is insufficient
evidence of API, Compose, builder, rootless or device compatibility.

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
compatibility or streaming acceptance. Those remain separate milestone gates.

The separate, opt-in `flake/checks/forgejo-podman-paths-vm.nix` fixture exercises a
synthetic Forgejo local executor against a rootless Podman API beside Docker. Run
it with the repository root flake's actual `inputs.nixpkgs` source, for example:

```sh
nixpkgs_path=$(nix eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
nix-build --no-out-link --option max-jobs 1 --option cores 2 --expr "let pkgs = import $nixpkgs_path {}; in import ./flake/checks/forgejo-podman-paths-vm.nix { inherit pkgs; }"
```

The tested Docker buildx container driver needs a cgroup parent within the
delegated Podman service, `default-load=true` for ordinary tagged `docker build`
output, and `BUILDX_BUILDER` to select that builder for `docker build`. This VM
does not qualify hosted workflows, registry pushes, or a production runner
module. It remains outside standard flake checks.

Host evidence and recovery procedures belong in the private operational
repository. Deployment manifests remain owned by GitOps; public host interfaces
and generic qualification checks remain here.

Track implementation in the [Podman adoption milestone](https://git.alc.xyz/alcxyz/nix-config/milestone/323)
and issues #433–#439.
