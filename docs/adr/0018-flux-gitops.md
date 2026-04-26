# ADR-0018: Flux as the GitOps operator for k3s

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** k3s cluster, infrastructure

## Context

ADR-0017 established k3s as the orchestration layer, replacing Docker Compose. A GitOps operator is needed to reconcile cluster state from git — keeping deployments declarative and auditable rather than manually applied with `kubectl`.

## Decision

Use Flux (Flux CD v2) as the GitOps operator. Flux controllers run in-cluster and continuously reconcile desired state from a git source.

## Alternatives Considered

- **ArgoCD** — feature-rich with a web UI for visualizing sync state and rollbacks. However, it is significantly heavier (~500MB+ RAM for server components) and the UI adds operational surface area without proportional benefit for a single-operator homelab. Better suited to multi-team environments.
- **Manual kubectl apply** — no automation overhead, but no drift detection, no audit trail, and error-prone as service count grows.

## Consequences

- **Easier:** Deploying and updating services is a git push. Drift detection and auto-reconciliation prevent manual-apply divergence. Lightweight footprint fits the NUC hardware.
- **Harder:** No built-in UI — cluster state is inspected via `flux` CLI and `kubectl`. Debugging sync failures requires reading Flux logs/events rather than clicking through a dashboard.
- **Trade-off:** Lower resource usage and simpler operations at the cost of visual tooling. Acceptable for a single-operator setup.
