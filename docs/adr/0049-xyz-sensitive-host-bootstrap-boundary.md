# ADR-0049: xyz sensitive host bootstrap boundary

**Status:** Accepted
**Date:** 2026-05-14
**Applies to:** `hosts/xyz`, private bootstrap material

## Context

`xyz` has host-specific bootstrap and recovery requirements that are more
sensitive than ordinary declarative NixOS service configuration. The public
repository should not describe detailed local security procedures, credential
lifecycle, recovery procedures, or operational assumptions.

## Decision

Keep sensitive host bootstrap design and procedures private.

The public repo may contain only the minimum NixOS integration needed to connect
generic boot-time services. It must not document host-specific enrollment
commands, credential storage, recovery procedures, threat-model details, or
known operational weaknesses.

## Repository Boundary

Use the existing private `nix-secrets` repository for host-specific runbooks and
bootstrap notes related to this area, for example under a private
`docs/runbooks/hosts/xyz/` path. This keeps the sensitive operational model with
the rest of the private host recovery material.

Do not create a new private flake initially. A separate private flake is only
worth adding if this becomes reusable software with its own tests, package
outputs, or host-independent module API.

## Alternatives Considered

- **Document the detailed policy publicly** - rejected because it exposes
  host-specific security assumptions.
- **Create a new private flake immediately** - rejected until there is reusable
  code or a host-independent module boundary to justify the extra repository.
- **Keep all related configuration private** - rejected for now because some
  generic NixOS integration may still need to live in the host configuration.

## Consequences

- **Easier:** The public repository has a clear boundary for what not to
  document.
- **Harder:** Operators need private material to understand and maintain the
  exact unlock policy.
- **Trade-off:** Public history still shows that a private bootstrap boundary
  exists, but not the implementation details.
