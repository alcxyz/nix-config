# ADR-0082: Release a self-fence only on positive peer evidence

**Status:** Accepted
**Date:** 2026-10-04
**Applies to:** `modules/nixos/virtualisation/k3s/` (`node-self-fence`), `kreboot`, `koff`, `kon` (nix-packages `k8s-node-reboot`), ADR-0068, gitops ADR-058

## Context

Each k3s server runs `node-self-fence` (gitops ADR-058). A node the cluster
can no longer count on reboots into a fence: a persistent marker keeps k3s
stopped until the agent decides that restarting it cannot bring old workloads
back while the cluster releases their volumes.

When a peer API server answers, the agent waits for release evidence from it.
When no API server answers, the agent has to guess. Two guesses have failed
review:

- **Counting peers that accept a connection on the API port.** A partial
  partition can show a node peers that are reachable but still form a quorum
  without it.
- **Waiting longer than any release could take.** The controller's countdown
  restarts with the controller, and a peer's startup errors can keep resetting
  the wait, so no fixed wait is guaranteed to outlast a release.

Reachability and timing cannot tell a fenced node what the rest of the cluster
is doing. The current fallback also recovers poorly from a fleet-wide fence:
the first node to restart k3s sees its peers' API ports refuse connections,
treats that as isolation and fences again, unless every node returns at about
the same time.

`kreboot` (ADR-0068) does not know about fencing. Rebooting one of three
servers while another is fenced, fencing or counting toward a fence removes
the etcd quorum, so routine maintenance could fence the whole cluster. After a
reboot it returns the node to scheduling without checking that the agent is
protecting it again.

## Decision

### Fence-state endpoint

Each agent serves its own state to peer servers on a dedicated TCP port
(`selfFence.statePort`, 9097 by default), opened in the firewall for the
configured peers. The pod network interfaces are trusted by the host firewall,
so the agent also drops connections from any source other than loopback and
the configured peers before handling them. The endpoint runs whenever the
agent runs, including while fenced, and is independent of k3s.

A request carries a fresh random nonce. The response states the node name,
boot ID, agent mode, classification, whether the node is **fenced**, and how
and with which peers it last released a fence in this boot. It is
authenticated with HMAC-SHA256 over the response and the nonce, keyed with a
subkey derived from the shared k3s server token (`tokenFile`), which every
server already holds. Requiring the nonce prevents replay without depending
on clocks. A response that does not verify, comes from another address or
arrives after the probe timeout counts as no answer. The key file is
`selfFence.keyFile`, which defaults to `tokenFile`; it is read on every use,
so a token rotation needs no restart. If the endpoint cannot start, the agent
keeps fencing without it and retries: until then peers cannot verify the node
and hold their own fences.

A node reports `fenced` only when its marker is in the `fenced` phase (the
fencing reboot happened) and `k3s.service` is not active. It stops reporting
`fenced` before it starts k3s.

### Release rule

With `N` configured servers and an etcd quorum of `Q = floor(N/2) + 1`, a
fenced node restarts k3s when either condition has held for `UNFENCE_STABLE`
seconds and still holds on a final check immediately before the start:

1. **Release evidence (unchanged).** An API server answers with release
   evidence for this node. API reads are linearizable, so one such answer is
   authoritative; otherwise any API answer holds the fence.
2. **No possible quorum.** No API server answers, and at least `N - Q + 1`
   servers, counting this one, are verified fenced through the endpoint. The
   remaining servers then cannot form a quorum, so no release can be in
   progress. For three servers, one other fenced peer is enough. A peer also
   counts if it released under this rule within the last 60 seconds and named
   this node among the fenced peers it counted. That joint evidence also lets
   this node skip its own release backoff, which could outlast the window.

Anything else holds the fence: a peer that accepts connections but does not
answer, a healthy or counting peer, an observe-mode or stopped agent, or a
response that does not verify. The TCP-reachability fallback and the fixed
release-outlasting wait are removed.

Restarting k3s under rule 2 is safe for the same reason a fresh boot is: the
node-fence-controller starts a new countdown after any gap in its view of the
API (gitops ADR-058), so the countdown cannot start before quorum returns. The
restarted node is then within its post-unfence grace and the ordinary fence
budget. If it cannot rejoin, it fences again with backoff.

The joint-release clause lets nodes that rely on each other restart
together. Without it, the first to restart stops reporting `fenced`, the other
loses its evidence, and with a third server down neither can rejoin a quorum:
they would fence and release in turn. A joint release starts the second node
one poll after the first, so it adds seconds to the fresh-boot argument above.
Exploiting that gap needs a quorum to form within those seconds while the
second node reaches the first's endpoint but not its API, and even then the
second node runs no workloads until its kubelet reaches an API server.

After a fleet-wide fence the nodes restart k3s together without an operator,
and they still do when one server is down. A node that is still fenced once
the others have formed a quorum sees an API server again and uses rule 1.

### Node power operations

The agent provides a local status command that reports this node's state and
the authenticated states of its peers as JSON. `kreboot`, `koff` and `kon` run
it over their existing SSH connection to the target, so the workstation holds
no fence key. Extending ADR-0068:

- **Preflight:** for a server target, every server must report a running agent
  in its configured mode, a healthy classification and no fence, and none may
  have unfenced within the agent's refence window. No node may carry a stale
  controller out-of-service taint or `fence.alc.xyz/disabled` annotation.
  Otherwise the operation stops before cordoning.
- **Before the power action:** the target's agent is stopped explicitly, and
  the helper checks that its Node shows `fence.alc.xyz/agent-mode=stopped`, so
  the controller does not count a long `koff` as a failure.
- **Before uncordon:** the target's agent must report its configured mode,
  `healthy` and not fenced, with an agent heartbeat that the API server
  recorded after the node returned.

Hosts without an enabled agent skip these gates. A server whose agent should
run but does not answer is a hard stop.

## Alternatives considered

- **Keep a reachability or timing fallback.** Rejected: both have known
  counterexamples, and further tuning cannot close them.
- **Drop the fallback and release fleet-wide fences by hand.** Safe, but turns
  every switch outage longer than a minute into an operator task.
- **Restart in a fixed order (lowest-named node first).** Unnecessary: rule 2
  lets every fenced node start at once, and ordering adds a wait without
  improving safety.
- **A separate shared secret for the endpoint.** Adds secret wiring and
  rotation for no gain; every server already holds the k3s token, and anyone
  with it can already join the cluster.

## Consequences

- One more listening port on every server, reachable from peers only.
- The agent becomes a small network service, and its tests must cover the
  endpoint, authentication and the release rule, including partial partitions
  and a fleet-wide fence.
- Rotating the k3s token rotates the endpoint key on next use. Servers
  holding different tokens cannot verify each other and hold their fences
  until the rotation completes.
- Enforce mode (gitops ADR-058) waits for this change and for the `kreboot`
  preflight gate, because once enforce is on, a maintenance mistake can fence
  the cluster.
