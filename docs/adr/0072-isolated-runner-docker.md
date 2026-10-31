# ADR-0072: Isolate runner Docker execution in a bounded rootless service

**Status:** Accepted
**Date:** 2026-09-10
**Amended:** 2026-10-31, the pressure guard, its freeze, the lifecycle teardown boundary and the hold monitor give way to the runner hold of [ADR-0106](0106-runner-hold-for-games-and-low-disk.md) ([#916](https://git.alc.xyz/alcxyz/nix-config/issues/916))
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

Dedicated Docker volumes are never swept automatically. When one must go,
an operator removes it with Docker's own CLI in a maintenance window with the
runners stopped ([ADR-0105](0105-offline-podman-store-reset.md)).

The option stays disabled by default. Fleet hosts explicitly opt in, and the
runner-pool check verifies their shared settings. Changing daemon GC settings
requires a controlled application to the running daemon; switching a unit with
`restartIfChanged = false` alone does not establish runtime activation.

Where a host sets `registryMirror` (xyz, xev, nex and nux), the dedicated
Docker daemon and the Podman API try that LAN pull-through cache first for
docker.io images and fall back to docker.io when it is unreachable or lacks an
image, so the cache stays a soft dependency. A cache that answers the first
request but fails later in a pull, for example on a platform manifest, can
still fail that pull in Podman, which keeps using the source that served the
image index. Pulls stay anonymous over TLS verified against the cache's own
CA (`registryMirrorCaFile`), which each engine trusts for the cache's host name
only, through its per-host `certs.d` directory, not the system trust store. The
cache runs on the same home infrastructure the runners already trust, and it
may resolve a tag to its cached digest until it refreshes the tag. Buildx
`docker-container` builders that jobs create keep their own registry
configuration and are not covered.

Use a dedicated rootless Docker daemon in a delegated systemd service below the
existing aggregate build slice. Its daemon and worker descendants inherit the
slice's CPU/memory budget. The runner connects only to that daemon and loses its
host Docker group membership. The daemon owns separate runtime state, images,
volumes and build cache. User-namespace networking leaves host Docker separate.

No controller pauses or freezes the aggregate. The runner hold of
[ADR-0106](0106-runner-hold-for-games-and-low-disk.md) decides when the
runners poll: it stops them while a game runs on the host or free space is
below the disk floor, and starts them again afterwards. A runner stop is an
ordinary graceful stop that the daemon and its workers outlive; the runner
cancels jobs that outlast its shutdown timeout. The free-space floor is a
sampled admission hold, not a storage quota: running jobs keep writing, and
cache cleanup and operator recovery remain needed when the filesystem is
critically full. Losing the hold stops no runner and no engine.

The runner, daemon and resource-policy units do not restart when a
configuration switch changes them; new unit definitions take effect at a
planned restart or reboot. NixOS may still start an inactive runner wanted by
an active target during a switch, so each runner's root `ExecCondition` (the
runner hold's start gate) refuses a start while a hold reason applies. Both
engine APIs take the same start lock before they start, which orders them
after a Podman store reset's rename
([ADR-0105](0105-offline-podman-store-reset.md)). Daemon failures do not
auto-restart.

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
silently fall back to host Docker on incompatibility.

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

Restarting changed units during a configuration switch could start a runner
that the runner hold keeps stopped, and cancel running jobs.

## Qualification and consequences

The disposable fixture `flake/checks/forgejo-isolated-docker-vm.nix` passes daemon
startup, runner-user socket access, ordinary container and nested Docker-build
worker ancestry, cgroup override containment, the 50% aggregate CPU ceiling,
40% memory throttling and the 50% hard memory ceiling. The memory fixture raises
only its soft threshold to reach the unchanged hard limit promptly and selects
a disposable allocator as the OOM victim. `OOMPolicy=continue` prevents systemd
from stopping the entire daemon service after a descendant is killed; it does
not guarantee which process the kernel selects under production pressure.
It uses a locally built dummy image and never registers a runner. Run it
explicitly with:

```sh
nix-build --no-out-link --impure --max-jobs 1 --cores 2 \
  --expr 'let pkgs = import (builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath {}; in import ./flake/checks/forgejo-isolated-docker-vm.nix { inherit pkgs; }'
```

The positive fixture `flake/checks/forgejo-isolated-docker-paths-vm.nix` uses the
real local Forgejo executor without registration or external image pulls. It
verifies job, service, Docker action, nested container and buildx-container
ancestry, including an actual BuildKit RUN worker. Job and action socket mounts
point at the dedicated daemon, and a manually paused host container stays
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

Nix evaluation and synthetic tests are necessary but insufficient. A runtime
canary must demonstrate job, step, service, Docker build and buildx
containment, preserved manual pauses and unaffected application Docker. Keep
migration and recovery procedures in the private operational repository.

A cold daemon needs additional storage and pulls. I/O weight does not
guarantee relief from buffered writes, and nothing enforces filesystem
capacity; the slot counts of [ADR-0106](0106-runner-hold-for-games-and-low-disk.md)
are the I/O lever. Shared-job credential isolation remains separate work.

The per-host rollout was tracked in
[#345](https://git.alc.xyz/alcxyz/nix-config/issues/345), closed on 2026-09-12
once all four runner hosts were qualified and enabled. Do not enable a further
host on the strength of synthetic tests alone.
