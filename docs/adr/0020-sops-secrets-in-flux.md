# ADR-0020: SOPS decryption for Kubernetes secrets via Flux

**Status:** Accepted, redacted
**Date:** 2026-04-26
**Applies to:** Kubernetes secrets management, Flux

## Context

Services managed through GitOps need credentials in Kubernetes without storing
plaintext values in git. The existing configuration already uses SOPS with age
encryption, and Flux can decrypt encrypted Kubernetes manifests during
reconciliation without another secrets operator.

## Decision

Use Flux's built-in SOPS support in `kustomize-controller`. Kubernetes Secret
manifests are committed in encrypted form, and each applicable Flux
`Kustomization` declares SOPS as its decryption provider and references a
runtime-projected service identity.

Flux uses a dedicated age identity that is independent of any host SSH
identity. This keeps host replacement and SSH key rotation separate from the
controller's ability to reconcile encrypted manifests.

### Source-of-truth boundary

Flux-managed encrypted manifests are the Kubernetes delivery mechanism. They
are not automatically the canonical owner of every value they deliver.

Long-lived values remain canonical in the private secrets repository when they
are operator-owned, shared with another control plane, or require a private
source outside the Kubernetes manifest shape. The GitOps Secret is then a
runtime projection of that canonical value. GitOps may be canonical for a
Kubernetes-only generated value when an owning runbook or ADR explicitly says
so.

The private `nix-secrets` Kubernetes runbooks own identity provisioning,
bootstrap, recovery, rotation, concrete credential locations, and operator
cluster-access procedures. The GitOps repository owns the Flux installation,
encrypted manifests, reconciliation policy, and cluster-side bootstrap helper.

## Alternatives Considered

- **Reuse a host SSH identity:** Fewer identities to manage, but couples Flux
  decryption to host replacement and SSH key rotation.
- **Sealed Secrets:** Requires a separate controller and encryption workflow.
- **External Secrets Operator:** Adds an external secret-store dependency that
  this design does not otherwise require.
- **A third-party SOPS operator:** Adds an operator when Flux already provides
  the required capability.
- **Unencrypted Kubernetes Secrets in git:** Does not protect secret values.

## Consequences

- SOPS and age remain the common encryption mechanism across NixOS and
  Kubernetes delivery paths.
- Flux can reconcile encrypted manifests without an additional secrets
  operator.
- Bootstrap and rotation require coordination between the private canonical
  source and the GitOps runtime projection.
- Concrete lifecycle and recovery details stay in private runbooks rather than
  this public architecture record.
