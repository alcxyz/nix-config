# ADR-0059: File-selective home backup and host storage monitoring

**Status:** Accepted, amended 2026-09-10

**Date:** 2026-08-11

**Applies to:** `xyz`, home backup, local backup storage, host storage monitoring

## Context

Whole-dataset home replication retained large rebuildable trees together with
valuable user files and could not express file-level exclusions. It also lacked
a clear repository capacity boundary. Manual inspection did not provide durable
evidence that scheduled backup and storage jobs continued to succeed.

## Decision

Use an encrypted Restic repository for file-selective protection of valuable
home data. Read from a temporary, read-only ZFS snapshot so each run sees a
consistent view, then remove that snapshot after the backup completes.

Exclude reviewed classes of rebuildable and high-churn data by default. Apply a
retention policy, repository maintenance, integrity checks, restore tests, and a
capacity limit. Concrete paths, exclusion patterns, schedules, retention values,
repository credentials, and storage identifiers belong in private
configuration.

Retain a previous backup representation only through a bounded transition. It
may be removed after the replacement has completed an initial backup, integrity
verification, restore test, and a later incremental backup.

Run host-level storage monitoring on systems that own storage. Check the
availability and writability of expected storage, free-space floors, required
services, and recent success of backup or mirror jobs. Send results to the
existing private Healthchecks endpoint. Beszel owns percentage-based capacity
history and sustained resource alerts; host checks retain ZFS-specific
correctness checks that generic metrics cannot prove. Alert endpoints and
host-specific thresholds remain private.

Record successful scheduled work in root-owned durable state only after the
operation exits successfully. Failed, canceled, or signaled runs do not advance
the marker. Replace markers atomically, reject malformed or future timestamps,
and allow only a bounded first-run exception. Activation must not invent prior
success. This preserves freshness evidence across reboot.

The cross-repository alert ownership and reconciler policy is recorded in
GitOps ADR-048. Private backup and monitoring detail follows
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Acceptance contract

- The selected source must be read from a consistent, read-only ZFS snapshot.
- Exclusion and retention policy changes require review.
- Repository integrity and a representative restore must pass before retiring
  the prior backup representation.
- Monitoring must detect unavailable or read-only storage, capacity breaches,
  inactive required services, and stale jobs without treating activation or a
  reboot as success.
- A local backup must not be described as whole-host or site-loss protection.

## Consequences

- Valuable home files receive versioned, encrypted, snapshot-consistent local
  protection without copying rebuildable bulk data.
- Individual files can be restored without recreating a filesystem layout.
- Repository maintenance can reclaim unreferenced data.
- Exclusion mistakes can omit valuable data and therefore need review.
- Storage correctness and job freshness remain distinct from generic capacity
  telemetry.

## Alternatives considered

### Continue whole-dataset replication

Rejected because it cannot express the intended file-level boundary without a
more complex home layout.

### Split the home into more datasets

Rejected because it adds layout and mount complexity primarily for the backup
tool.

### Back up live files directly

Rejected because a read-only ZFS snapshot gives Restic a consistent view.

### Infer recent success from transient service state

Rejected because service-manager timestamps and results do not preserve
freshness evidence across reboot and may confuse startup with completed work.
