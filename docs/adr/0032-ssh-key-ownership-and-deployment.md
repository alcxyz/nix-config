# ADR-0032: SSH Key Ownership and Deployment

**Status:** Accepted, redacted
**Date:** 2026-05-03
**Applies to:** common NixOS configuration, Home Manager, private SSH policy

## Context

Inbound login authorization, host-local identities, operator credentials and
distributed-build authentication have different owners and lifecycles. Keeping
them separate avoids accidental expansion of access when adding a consumer.

## Decision

Inbound SSH authorization is NixOS-managed system policy through
`users.users.<name>.openssh.authorizedKeys`. Home Manager does not own the normal
inbound authorization file.

The private `sshAccessPolicy` module owns the concrete public-key catalog,
known-host mappings and account authorization assignments. The public common
module imports that policy and retains generic system configuration. The
extraction preserves the existing generated access policy; it does not grant or
revoke access.

The private NixOS and Home Manager `sshIdentityPolicy` exports own host-local
and operator identity projections and their platform-specific activation
integration. The common modules import these policies directly.

Host-local identities, operator identities and dedicated build-client identities
retain separate lifecycles. System-managed identities needed before user
activation remain a system responsibility. Private storage locations, membership,
rotation order and deployment procedures are documented in `nix-secrets`.

## Alternatives Considered

- **Manage inbound authorization through Home Manager:** rejected because
  system access must not depend on a later user activation.
- **Reuse general host identities for unrelated build or operator workflows:**
  rejected because separate purposes need independently reviewable access.
- **Keep concrete access assignments in the public common module:** rejected
  under the private-material boundary; standard NixOS interfaces remain public.

## Consequences

SSH policy remains declarative and available during system activation. Changes
to private key membership or host mappings require review in the private owner.
Source extraction must compare generated known-host and account authorization
outputs across all configured NixOS hosts before adoption.

Current-tree redaction does not remove earlier published versions. Historical
source and tracker review remain separately tracked in the private audit.
