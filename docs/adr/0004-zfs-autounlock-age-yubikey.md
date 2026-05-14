# ADR-0004: Private encrypted pool unlock boundary

**Status:** Accepted, redacted 2026-05-14
**Date:** 2026-04-18
**Applies to:** encrypted pool unlock integration, private bootstrap material

## Context

Some host storage is encrypted outside the root filesystem and must be prepared
before dependent services start. The exact unlock chain, identity ordering,
credential locations, and recovery procedure are sensitive host bootstrap
material.

## Decision

Keep the public repository limited to generic encrypted-pool service wiring.
Host-specific unlock policy, identity paths, credential lifecycle, and recovery
procedures live in the private infrastructure repository.

## Alternatives Considered

- **Document the full unlock design publicly** - rejected because it exposes
  private host bootstrap assumptions.
- **Keep all service wiring private** - rejected for now because generic module
  wiring can remain public without the host-specific policy details.

## Consequences

- Public documentation records only the architectural boundary.
- Operators need the private runbook for implementation, recovery, and changes.
- Future public module examples should avoid host-specific identity paths.
