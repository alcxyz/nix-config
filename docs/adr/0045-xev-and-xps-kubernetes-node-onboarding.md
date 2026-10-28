# ADR-0045: xev and xps Kubernetes node onboarding

**Status:** Accepted
**Date:** 2026-05-11
**Amended:** 2026-10-28
**History:** [replaced text](archive/0045-xev-and-xps-kubernetes-node-onboarding-history.md)
**Applies to:** host inventory, Kubernetes roles, storage eligibility, and runner capacity

## Context

The cluster needed more stable compute and storage capacity, while a mobile
workstation was also being added to the public host inventory. Those machines
have different availability and lifecycle characteristics and should not receive
the same Kubernetes role by default.

Detailed access, hardware qualification, network, bootstrap, and deployment
information is private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

`xev` is a stable Kubernetes server-worker (`k8sRole = "server-worker"` in
`inventory.nix`). It runs normal workloads, provides cluster storage, and adds
native runner capacity; each capability is enabled only after it passes its
own readiness checks. Its membership of the server set is recorded by
[ADR-0051](0051-xev-replaces-rpi0-k3s-server.md).

Keep `xps` workstation-first and outside Kubernetes (`k8sRole = null`). Any
future worker or GPU role requires a separate decision based on its
availability and operating characteristics. Do not use it for cluster storage
under this decision. Workstations stay outside cluster membership in steady
state ([ADR-0061](0061-retire-xyz-k3s-agent.md)).

Public Nix configuration owns generic role declarations and host-readiness
interfaces. Runtime workload placement remains owned by GitOps, and private
material owns concrete onboarding procedures.

## Acceptance Contract

Before enabling a cluster capability on a host, validate the declarative host
configuration, expected node role, cluster observability, and any storage
prerequisites. Enable storage and runner duties independently so each has a
clear qualification boundary.

## Alternatives Considered

**Add another server without preserving the intended quorum shape**: rejected.
Server membership changes must preserve the deliberate odd-sized control plane.

**Treat stable capacity as ephemeral**: rejected because the stable host is
intended to carry normal cluster workloads.

**Join the workstation immediately**: rejected because mobility and variable
availability make it unsuitable as a default cluster dependency.

**Enable cluster storage on every compatible machine**: rejected because
storage eligibility requires stronger availability and capacity guarantees than
compute eligibility.

## Consequences

`xev` adds compute, storage, runner, and control-plane capacity. The
workstation remains independently useful without becoming part of the cluster
failure domain.
