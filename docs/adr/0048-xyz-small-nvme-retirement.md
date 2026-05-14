# ADR-0048: xyz storage maintenance private runbook boundary

**Status:** Accepted, redacted 2026-05-14
**Date:** 2026-05-13
**Applies to:** `hosts/xyz`, private storage maintenance runbooks

## Context

Some `xyz` storage maintenance involves encrypted pools, live service
dependencies, exact device identities, and host-specific verification gates.
Those details are private operational material and should not be documented in
the public repository.

## Decision

Move detailed `xyz` storage maintenance procedures into the private
infrastructure repository. Keep this public ADR as a boundary record only.

## Alternatives Considered

- **Keep detailed storage runbooks public** - rejected because device identity,
  service dependency, and recovery details are private operational material.
- **Keep no durable runbook** - rejected because storage work still needs
  explicit verification gates and rollback notes.

## Consequences

- Public documentation no longer carries the operational procedure.
- Operators need the private runbook before performing storage maintenance.
