# ADR-0020: SOPS decryption for Kubernetes secrets via Flux

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** k3s cluster, secrets management, Flux

## Context

Services migrating from Docker Compose to Kubernetes (ADR-0017) need their secrets (database passwords, API tokens, etc.) available in-cluster. The existing infrastructure uses SOPS with age encryption for all secrets (ADR-0003). Docker Compose services consume secrets via `secrets.env` files decrypted by SOPS at deploy time.

A Kubernetes-native secrets strategy is needed that:
- Keeps encrypted secrets in git (GitOps principle)
- Integrates with Flux (ADR-0018) without additional operators
- Fits into the existing age key lifecycle (see nix-secrets README)

## Decision

Use Flux's built-in SOPS decryption support in `kustomize-controller`. Kubernetes Secret manifests are committed to git encrypted with SOPS (age backend), and Flux decrypts them during reconciliation.

### Flux gets a dedicated age keypair

Flux uses its own standalone age identity, generated via `age-keygen` — not derived from nux's SSH host key. This decouples Flux decryption from host key rotation: if nux is reinstalled or its SSH key changes, the Flux key in the cluster continues to work.

**Key lifecycle:**
1. Generate: `age-keygen -o /tmp/flux.agekey`
2. Store private key: encrypted in `nix-secrets/hosts/nux/secrets.yaml` under key `flux_age_key`
3. Deploy to nux: sops-nix decrypts it to `/run/secrets/flux_age_key` at activation
4. Bootstrap into cluster: `bootstrap-sops.sh /run/secrets/flux_age_key` creates a `sops-age` Secret in `flux-system` namespace
5. Register public key: added as a recipient in the gitops repo's `.sops.yaml` for `k8s/**/*.sops.yaml` paths
6. Delete plaintext: `/tmp/flux.agekey` is removed after step 2

The Flux public key is also added as a recipient alongside user keys, so operators can still encrypt/decrypt k8s secrets locally.

### Encryption workflow

```bash
# In the gitops repo:
# 1. Create a k8s Secret manifest with plaintext values
# 2. Encrypt in-place — .sops.yaml selects Flux + user keys as recipients
sops -e -i k8s/apps/hedgedoc/secret.sops.yaml
# 3. Commit the encrypted file — Flux decrypts at apply time
```

### Flux Kustomization configuration

Each Flux `Kustomization` references the decryption secret:
```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

## Alternatives Considered

- **Reuse nux's SSH host key** — simpler (no new key to manage), but creates tight coupling: SSH key rotation breaks Flux, and the host key would need to be copied into the cluster as a Kubernetes Secret. The dedicated key is operationally cleaner.
- **Sealed Secrets** — requires a cluster-side controller with its own key pair. Adds an operator to manage and a different encryption tool (`kubeseal`). Does not reuse existing age keys.
- **External Secrets Operator** — pulls secrets from external stores (Vault, AWS SSM, etc.). No external secret store exists in this setup; would add unnecessary complexity.
- **SOPS Operator (isindir/sops-secrets-operator)** — third-party CRD-based approach. Adds an operator when Flux already has native support for the same functionality.
- **Plain Kubernetes Secrets (no encryption)** — secrets in git as base64 (trivially reversible). Violates GitOps security principles.

## Consequences

- **Easier:** Single encryption tool (sops/age) across NixOS secrets, Docker secrets.env, and Kubernetes secrets. No additional operators to install or manage. Encrypted secrets live alongside manifests in git.
- **Harder:** Two-step bootstrap — the Flux age key must be stored in nix-secrets (for persistence) and loaded into the cluster (for runtime use). Key rotation requires updating both the cluster Secret and re-encrypting affected files in the gitops repo.
- **Trade-off:** A new key to manage, but with a clear lifecycle (generated once, stored in nix-secrets, deployed via sops-nix, bootstrapped into k8s). The alternative — reusing the host SSH key — would be simpler upfront but more fragile over time.
