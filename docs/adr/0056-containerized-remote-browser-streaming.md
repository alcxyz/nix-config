# ADR-0056: Containerized remote browser streaming

**Status:** Accepted, implemented

**Applies to:** Wolf, Moonlight, browser sessions

**Lifecycle amendments:**
[ADR-0057](0057-kubernetes-managed-protected-browser-mobility.md) moved the
coordinators under Kubernetes while preserving the independent public and
protected identities established here.
[ADR-0061](0061-retire-xyz-k3s-agent.md) later retired the workstation worker
and its fallback placement.

**Artifact ownership amendment (implemented):**
[GitOps ADR-052](https://git.alc.xyz/alcxyz/gitops/src/branch/dev/docs/adr/ADR-052-registry-backed-runtime-images.md)
and
[nix-config issue #372](https://git.alc.xyz/alcxyz/nix-config/issues/372)
replace node-local image builds and mutable aliases with immutable registry
artifacts. The producer changes were accepted through
[PR #373](https://git.alc.xyz/alcxyz/nix-config/pulls/373),
[PR #374](https://git.alc.xyz/alcxyz/nix-config/pulls/374), and
[PR #376](https://git.alc.xyz/alcxyz/nix-config/pulls/376); the host consumer
change was accepted through
[PR #377](https://git.alc.xyz/alcxyz/nix-config/pulls/377); and the GitOps
consumer change was accepted through
[GitOps PR #1193](https://git.alc.xyz/alcxyz/gitops/pulls/1193). That adoption
did not include a new end-to-end Moonlight streaming test.

## Context

The couch client needs remote browsers for general and protected use without
making the game-streaming session responsible for browser lifecycle, profiles,
or packages. The browser stream must provide hardware video encoding, virtual
display modes, audio, keyboard, pointer, and cooperative input while keeping
persistent browser state isolated.

Concrete endpoint assignments, pairing material, protected-profile
configuration, credentials, state locations, and operational evidence are
private under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Run Wolf as a pinned container on a qualified GPU host and publish browsers as
separate container images. Keep browser homes persistent and isolated so
application settings, authentication, and upgrade lifecycles do not cross
browser boundaries. Browser containers retain their renderer sandbox and do
not install the browser packages globally on the host.

Keep cooperative public use and protected use in independent Wolf coordinator
identities. They have separate state, pairings, catalogs, lifecycle, and
recovery boundaries. The public identity exposes only its reviewed cooperative
application; protected applications remain behind the protected coordinator's
private policy. A failure or restart in one coordinator must not stop sessions
owned by the other.

Clients choose their connection class explicitly. Fixed clients use a local
route policy; roaming clients may use another declared policy. Launchers update
only the selected endpoint and leave pairing and application state intact.
Concrete hostnames and route assignments remain private.

Use Moonlight's remote-desktop pointer mode. The client compositor retains its
system shortcuts while ordinary input reaches the remote application. Keyboard
layout policy is applied consistently to the outer virtual session and nested
browser compositor. Cooperative phone input keeps its own identity and remains
separate from host-local input identities.

Treat persistent browser homes as single-writer state. Each application locks
its home for the container lifetime and may remove only known stale locks from
a prior disposable container. Reconciliation owns only declared applications
and preserves unowned entries, pairings, certificates, and homes.

Give each coordinator independent encoder, pipeline, and resource watchdogs.
Guarded recovery waits while an active session on the affected coordinator
could be disrupted, then restarts only that coordinator and retains persistent
browser homes. Recovery in one coordinator must not stop the other. Bound every
optional desktop-shell IPC call so client teardown does not depend on the shell
remaining responsive.

Nix owns the pinned browser inputs, build contexts, and runtime behavior.
Trusted Forgejo CI builds and publishes immutable registry artifacts, verifies
registry read-back, and makes those exact references available to host and
GitOps consumers. Consumers use immutable references and do not rebuild images
at startup.

The game-streaming deployment remains a separate lifecycle and regression
boundary. Browser startup, cleanup, or failure must not mutate it.

## Acceptance contract

- Qualify the declared client mode with hardware encode and decode, audio,
  keyboard layouts, pointer movement, primary clicking, cooperative phone input,
  and controller exit behavior.
- Treat pointer movement and primary clicking as one input contract. A rollout
  does not pass if only one works.
- Verify that public and protected identities retain separate state and that
  restarting one does not stop the other.
- Verify that guarded watchdog recovery waits for active sessions, affects only
  the unhealthy coordinator, and retains its persistent homes.
- Verify persistent-home locking, resume after an interrupted session, and
  bounded cleanup of abandoned containers without discarding browser state.
- Verify client teardown completes when optional desktop-shell IPC is
  unavailable.
- Verify immutable artifact publication, read-back, and exact consumption by
  both host and GitOps definitions.
- Keep any unqualified hardware, input, client, or runtime combination pending;
  artifact adoption alone does not qualify end-to-end streaming.

The original implementation passed its historical streaming acceptance. The
September 2026 registry migration passed producer and consumer acceptance, but
its end-to-end Moonlight streaming gate remains unclaimed.

## Alternatives considered

### Run browsers inside the game-streaming session

Rejected because browser profiles, updates, input, and cleanup need an
independent lifecycle and must not interfere with game streaming.

### Install all browsers directly on the streaming host

Rejected because it couples browser packages and state to the host and weakens
per-browser isolation.

### Combine public and protected sessions in one coordinator

Rejected because it collapses catalog visibility, pairing, state, and recovery
boundaries.

### Build mutable images on each runtime host

Superseded by the artifact ownership amendment. Trusted CI now publishes the
immutable images consumed by hosts and GitOps.

## Consequences

- Browser rendering moves to a qualified GPU host while Moonlight retains the
  couch-client experience.
- Public and protected browser identities remain independent even when they
  share infrastructure.
- Containerized browsers require broad, carefully bounded access to graphics
  and input devices.
- Registry adoption makes the build and deployment artifact reviewable across
  producer and consumers; it does not by itself prove streaming behavior.
