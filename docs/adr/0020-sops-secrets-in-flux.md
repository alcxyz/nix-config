# ADR-0020: SOPS decryption for Kubernetes secrets via Flux

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** k3s cluster, secrets management, Flux

## Context

Services migrating from Docker Compose to Kubernetes (ADR-0017) need their secrets (database passwords, API tokens, etc.) available in-cluster. The existing infrastructure uses SOPS with age encryption for all secrets (ADR-0003). Docker Compose services consume secrets via `secrets.env` files decrypted by SOPS at deploy time.

A Kubernetes-native secrets strategy is needed that:
- Keeps encrypted secrets in git (GitOps principle)
- Reuses existing age keys rather than introducing new key material
- Integrates with Flux (ADR-0018) without additional operators

## Decision

Use Flux's built-in SOPS decryption support in `kustomize-controller`. Kubernetes Secret manifests are committed to git encrypted with SOPS (age backend), and Flux decrypts them during reconciliation.

**Setup:**
1. The age private key (already on nux via sops-nix at `/run/secrets/`) is loaded into a Kubernetes Secret in the `flux-system` namespace
2. Each Flux `Kustomization` resource references this decryption secret via `spec.decryption.provider: sops`
3. Secret manifests in git are standard Kubernetes Secrets with values encrypted by `sops -e -i`

**Encryption workflow:**
```bash
# Create a k8s Secret manifest with plaintext values
# Then encrypt in-place with sops
sops -e -i apps/hedgedoc/secret.yaml
# Commit the encrypted file — Flux decrypts at apply time
```

## Alternatives Considered

- **Sealed Secrets** — requires a cluster-side controller with its own key pair. Adds an operator to manage and a different encryption tool (`kubeseal`). Does not reuse existing age keys.
- **External Secrets Operator** — pulls secrets from external stores (Vault, AWS SSM, etc.). No external secret store exists in this setup; would add unnecessary complexity.
- **SOPS Operator (isindir/sops-secrets-operator)** — third-party CRD-based approach. Adds an operator when Flux already has native support for the same functionality.
- **Plain Kubernetes Secrets (no encryption)** — secrets in git as base64 (trivially reversible). Violates GitOps security principles.

## Consequences

- **Easier:** Single encryption tool (sops/age) across NixOS secrets, Docker secrets.env, and Kubernetes secrets. No additional operators to install or manage. Encrypted secrets live alongside manifests in git.
- **Harder:** Flux's SOPS support requires the age key to be manually bootstrapped into the cluster as a Kubernetes Secret. Key rotation requires updating both the cluster Secret and re-encrypting affected files.
- **Trade-off:** Tighter coupling to Flux (decryption is a Flux feature, not a standalone operator). Acceptable since Flux is already the chosen GitOps tool (ADR-0018).
