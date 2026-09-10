# ADR-0072: Isolate runner Docker execution in a bounded rootless service

- Status: Proposed; disposable-VM qualification, host canary pending; disabled by default
- Date: 2026-09-10
- Area: Forgejo runners, Docker, systemd

## Context

Runner-applied container options and labels do not reach Docker and BuildKit
workers created through a mounted daemon socket. Limits must cover daemon-side
execution as well as outer job containers, without changing application Docker.

## Decision proposed

Use a dedicated rootless Docker daemon in a delegated systemd service below the
existing aggregate build slice. Its daemon and worker descendants inherit the
slice's CPU/memory budget. The runner connects only to that daemon and loses its
host Docker group membership. The daemon owns separate runtime state, images,
volumes and build cache. User-namespace networking leaves host Docker separate.

The pressure controller stays outside the build slice and freezes the complete
aggregate under sustained pressure. It thaws only a freeze it owns; uncertain
operations fail closed for reconciliation. A slice thaw does not issue Docker
unpause calls, so individually paused containers remain paused.

Start the guard after the resource slice and before the daemon. The daemon binds
to guard health, so losing the controller stops existing worker descendants as
well as new runner dispatch. Recovery must explicitly restore daemon/runner
service after a controller failure; it must not silently resume interrupted jobs.

All runner clients, mounted sockets and cache maintenance use the dedicated
endpoint. The default remains unchanged until runtime qualification passes.

The system service owns the aggregate boundary. Rootless Docker may report no
per-container cgroup support without a user service manager; those individual
limits are not the contract. Qualification must prove ancestor limits remain
effective for ordinary builds and buildx workers, including cgroup overrides.
Use a dedicated unprivileged account and fuse-overlayfs for the initial
candidate; do not silently fall back to host Docker on incompatibility.

## Alternatives

A second rootful daemon with a default cgroup parent keeps existing behavior,
but the API can override that parent and its network setup still modifies host
firewall state. It does not by itself establish the required boundary.

Adding labels and resource flags to each workflow misses daemon-internal builds
and relies on every nested invocation remembering the convention.

A rootless user service can support per-container systemd cgroups, but adds a
user manager lifecycle and changes the aggregate placement model. Revisit this
if existing workflow compatibility requires those controls.

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
nix-build --no-out-link --expr 'let pkgs = import <nixpkgs> {}; in import ./flake/checks/forgejo-isolated-docker-vm.nix { inherit pkgs; }'
```

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
system-wide rootless services as unsupported. Keep the experimental status until
the bounded backing-filesystem canary and real hosted workflows pass. The fixture
preserves host-Docker manual pauses; it does not establish per-container pause
support inside the rootless daemon without per-container cgroups.

Nix evaluation and synthetic guard tests are necessary but insufficient. A
runtime canary must demonstrate job, step, service, Docker build and buildx
containment; pressure-induced loss of worker progress; owned recovery; preserved
manual pauses; and unaffected application Docker. Keep migration and recovery
procedures in the private operational repository.

A cold daemon needs additional storage and pulls. I/O weight and cgroup freezing
do not guarantee immediate relief from already queued buffered writes, nor do
they enforce filesystem capacity. Qualify pressure behavior on the actual
backing filesystem. Shared-job credential isolation remains separate work.

Tracks [#345](https://git.alc.xyz/alcxyz/nix-config/issues/345). Do not close it or
enable hosts on the strength of synthetic tests alone.
