# ADR-0103: Give CI jobs a read-only pull-through cache of the upstream Nix caches

**Status:** Accepted
**Date:** 2026-10-30
**Applies to:** `modules/nixos/services/forgejo-actions-runner/nix-cache-proxy.nix`,
`modules/nixos/services/forgejo-actions-runner/podman-canary.nix`, the Podman
runner pool on xyz, xev, nex and nux

## Context

Every Nix CI job runs in the rootless Podman runner pool (ADR-0074, ADR-0097,
ADR-0100) in a fresh `node:20-bookworm` container. It installs single-user Nix
with `cachix/install-nix-action` and starts from an empty store, so each run
downloads the same upstream paths again from cache.nixos.org and
nix-community.cachix.org. One measured five-minute validation run spent about
1.5 minutes of it on that warm-up (nix-config #894). nix-config #897 asks for a
cache that removes this cost without letting a job change what other jobs
trust.

nix-packages ADR-0003 already reuses its own fixed-output dependencies through
a directory-format binary cache in the per-repository Actions cache, and
deferred "a separate binary-cache service" until host locality and transfer
cost were measured. No CI runner may receive host store access or a host
daemon mount (ADR-0074), and jobs run unprivileged (ADR-0041). Jobs do reach
the runner's Podman API, so a job can start a container on the host's network
and reach any port on the host's loopback.

## Decision

- **An nginx pull-through cache of the upstream caches on each pool host.**
  Hosts with `services.forgejo-actions-runner.nixCacheProxy.enable` run one
  nginx process (`forgejo-nix-cache.service`) that is both the cache and its
  only listener. It serves each HTTPS substituter the host itself uses, once
  each (cache.nixos.org and nix-community.cachix.org), under a prefix named
  after the upstream's host, and fetches from the upstream with SNI and
  certificate verification against the host's CA bundle. It holds only what
  those upstreams serve, never a build output of ours. Upstreams are bare
  `https://host[/path]` URLs; the default takes the host's substituters
  without store parameters such as `?priority=`, and leaves out any with a
  port.
- **Resolved per request.** nginx resolves an upstream's name through the
  host's resolvers, which the unit reads from `/etc/resolv.conf` when it
  starts and whenever that file changes (a path unit reloads it), and
  re-resolves as the DNS records expire, so a CDN's changing addresses are
  followed. nginx starts without DNS; requests fail with 502 until a
  resolver answers.
- **Jobs trust no new key.** nginx stores and returns the upstream responses
  unchanged, so each narinfo keeps its upstream `Sig:` lines and no other.
  Jobs verify paths with the keys they already trust, so the trust boundary
  is unchanged; a path no trusted key signed is refused by the job.
- **Read-only for jobs.** There is no write endpoint to protect. Each prefix
  answers only `GET` and `HEAD` of `nix-cache-info`, `<hash>.narinfo` and
  `nar/<file>.nar[.<compression>]`; other methods get 403 and other paths
  404, from nginx itself. The prefix and any query are dropped before the
  upstream request and the cache key, so one object has one entry. Upstream
  caching headers are ignored: a 200 is kept until `inactive` (default 30
  days), a 404 for one minute, and nothing else is cached. Concurrent requests
  for one object share one upstream fetch (`proxy_cache_lock`).
- **Reached through Podman, refused to other hosts.** Rootless Podman's
  pasta maps `host.containers.internal` to the host's own address (not to its
  loopback), so job containers on the per-job networks the runner creates
  reach a host service listening there. The cache listens on all of the
  host's addresses at port 8501. pasta opens the job's connection from the
  host itself, so it arrives with the host's own address as its source
  (checked in the VM). The port is not opened in the firewall, and a rule in
  the `raw` table's `PREROUTING` (iptables, and ip6tables where IPv6 is
  enabled) drops traffic addressed to the host on that port from every
  source that is not one of the host's own addresses; traffic the host only
  forwards is untouched. It acts before any `INPUT` chain, so neither the
  NixOS firewall's trusted interfaces nor accept rules of kube-router or
  NetBird let the LAN, NetBird peers or pods on the pod network reach the
  cache. It does not restrict what runs on the host itself: local processes,
  host-network containers (which a job can start through the Podman API) and
  host-network pods still reach the read-only listener, and nothing more.
  The module requires the NixOS firewall with its iptables backend, whose
  start and reload hooks install the rule; neither the nftables nor the
  firewalld backend runs them.
- **Wired through the runner, not the workflows.** Each Podman runner sets
  `NIX_CONFIG` in its runner variables: one `extra-substituters` entry per
  upstream, such as
  `http://host.containers.internal:8501/cache.nixos.org?priority=10` and
  `.../nix-community.cachix.org?priority=11`, ahead of the upstreams'
  priorities 40 and 41, plus `fallback = true` and `connect-timeout = 5`.
  Single-user Nix as installed by `install-nix-action` reads it in every
  step. `fallback` makes Nix skip a substituter that fails instead of failing
  the job, so an outage of the cache costs speed only.
- **Bounded disk.** `nixCacheProxy.storagePath` (default
  `/var/lib/forgejo-nix-cache`) holds the cache, and the unit waits for its
  mount. `nixCacheProxy.maxSize` (default 10G) is a soft bound: nginx's cache
  manager evicts the least recently used entries when it finds the cache
  above it, asynchronously, and counts a file only once it is complete, so
  the cache can run over it while large downloads are in flight. The hard
  bound is a quota or a dedicated filesystem for `storagePath`, which the
  private flake should add on each host's CI disk; until it does, the cache
  lives on the root filesystem with the soft bound only.
- **Our own build outputs stay as they are.** They keep nix-packages ADR-0003's
  per-repository Actions cache. A signed shared cache for them is deferred
  until this cache has been measured.

The cache differs from the service nix-packages ADR-0003 deferred: it stores
no build output, so it needs no write boundary or signing key; it runs on the
host that runs the job, so transfers stay local; and losing it costs only
speed.

### Measurement

Repeat the nix-config #894 measurement (Forgejo task timestamps over three
days) once every pool runner has restarted with the new configuration, for
nix-packages `ci.yml`, pandora's `nix flake check` and the private validation
workflow: run median and p90, and the share of a run before its first Nix
build step. Read the cache's size from its storage on each host. Record
before and after on nix-config #897. The signed shared build cache is
reconsidered from those numbers.

## Alternatives Considered

- **Extend the per-repository Actions cache** to the other Nix workflows.
  Isolated and already proven, but every repository, and in practice every
  runner, warms its own copy, archives are size-limited, and each workflow
  must add save and restore steps.
- **A signed shared cache of our own build outputs**, written only by trusted
  post-merge runs. Saves more, but needs a signing key on the CI hosts, a
  write path no pull request job can reach, and a decision on who may sign.
  Deferred until this cache is measured.
- **A read-only substituter backed by xyz's store.** Exposes a host store to
  jobs, which ADR-0074 rules out, and serves only from one host.
- **ncps, the Nix cache proxy packaged in nixpkgs.** Understands narinfos and
  can check upstream signatures itself, but it is not read-only: its pin
  endpoints (`POST` and `DELETE` on `/pin/`), which exempt paths from
  eviction, cannot be turned off, so a job could grow its disk past the bound.
  A front that filters them does not help while ncps listens on loopback,
  which jobs reach through a host-network container. Its size bound is also
  only applied on a schedule.
- **One shared cache for all hosts.** Would warm once instead of four times,
  but needs a LAN or NetBird listener reachable from every job container and
  moves transfers off the job's host. Per-host instances keep the port closed
  to the network.
- **Setting the substituter in each workflow.** Needs edits in every
  repository and repeats the address; the runner variable covers every
  current and future job in the pool.

## Consequences

- A switch starts the cache and loads the firewall rule. The Podman runner
  units do not restart on a switch (`restartIfChanged = false`), so jobs get
  the new `NIX_CONFIG` only after each runner is restarted while idle, or its
  host reboots.
- Disabling the cache on a host leaves its `raw` chain, which drops other
  hosts' traffic to the host on the cache's port, until the host reboots or
  the chain is removed by hand. Reboot after disabling it before giving the
  port to another service.
- Runner variables take precedence over workflow-level and job-level `env`.
  A workflow that sets its own `NIX_CONFIG` there loses it; set it in a step's
  `env` instead, which takes precedence, and append the runner's value to
  keep the cache. `podmanCanary.jobEnv` may not set `NIX_CONFIG` while the
  cache is enabled.
- nginx's resolver takes addresses, not names, and does not read
  `/etc/hosts`; an upstream must resolve through the DNS servers in
  `/etc/resolv.conf`. Without any there, the unit names the systemd-resolved
  stub address, and lookups fail until a reload.
- The cache does not check signatures; the job does. A path an upstream serves
  that the job does not trust is cached but never used.
- An upstream that redirected NAR downloads elsewhere would bypass the cache
  for them (redirects are not cached). Neither upstream does today: both
  narinfos use relative `nar/...` URLs, served directly.
- While the cache is down, a job's connection to it times out rather than
  being refused. In the VM check each Nix process then lost about 30 seconds
  (five attempts at the 5-second `connect-timeout`) before skipping it for 60
  seconds. A stopped cache should be restarted, or the cache disabled,
  rather than left down.
- `fallback = true` also applies when an upstream fails: a path that no
  substituter delivers is built from source instead of failing the job.
- Nested containers a job starts itself (as the private validation workflow
  does) do not inherit the runner's variables; they opt in by passing
  `NIX_CONFIG` on. On a Podman bridge network they should reach the cache the
  same way, which is not yet qualified.
- Jobs on one host share the cache: one job can make another's download
  faster, or, by fetching many upstream paths, push others' entries out
  within `maxSize`. Nothing a job sends is stored except upstream responses.
- The cache's storage counts against the host's disk, bounded only softly,
  until the private flake gives `storagePath` a quota or its own filesystem.
- The `forgejo-nix-cache-proxy` flake check qualifies the cache in a VM with a
  local HTTPS binary cache, signed with a test key and served with a test CA,
  standing in for the upstreams: a Nix client in a job container substitutes
  through it trusting only the upstream key, the narinfo keeps the upstream
  signature, the job refuses an untrusted path, a second job is served with
  the upstream stopped, writes and other paths are refused, other hosts are
  refused over IPv4 and IPv6 (also past an early `INPUT` accept rule), the
  cache is the only listener of its unit, it resolves the upstream through
  the host's DNS server, starts while that server is down and resolves once
  it is back, and a stopped cache falls back to the next substituter.
