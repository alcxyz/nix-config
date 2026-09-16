# ADR-0063: Split replaceable bulk data from secure storage

**Status:** Accepted, implemented
**Date:** 2026-08-29
**Amended:** 2026-09-07
**Applies to:** `xyz`, replaceable bulk storage, secure storage, media services

## Context

One historical namespace had come to represent both mirrored encrypted storage
and capacity-oriented storage assembled from independent filesystems. Media
content that can be acquired again was consuming redundant secure capacity,
while application state referred to stable absolute content paths.

The two classes have different loss, backup, and maintenance expectations.
Keeping them under one storage policy obscured those expectations and made later
ownership changes harder to reason about.

## Decision

Use the stable application-visible namespace for replaceable bulk data backed by
mergerfs over independent XFS filesystems. Preserve consumer paths and required
filesystem metadata through the split so application state does not require an
unrelated rewrite.

The bulk layer is intentionally non-redundant and is not a backup. Loss of one
branch may lose the files placed there while leaving another branch readable.
Only explicitly classified replaceable data may live in this storage class.

Retain valuable and recovery-oriented data on mirrored, natively encrypted ZFS
storage under a distinct secure-storage identity. Keep any naming or mount
transition separate from the bulk copy, service cutover, and later physical
move. ADR-0064 keeps secure-storage ownership on `xyz`; ADR-0062 moves only the
replaceable bulk unit and its dependent services after its pending gates pass.

Services must require their real storage mount and fail safely rather than write
into an unmounted placeholder. Concrete pools, datasets, mount paths, branch
inventory, copy commands, and rollback procedures are private under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Acceptance contract

- Classify every source subtree as replaceable before placing it on bulk storage.
- Stop writers for the final transfer and verify content and required metadata
  before changing mounts.
- Preserve application-visible paths across the cutover.
- Validate dependent services, exports, and ordinary file access before
  retiring former secure copies.
- Authorize destructive cleanup separately from data movement and retain a
  bounded rollback point until validation completes.

## Alternatives considered

### Keep replaceable media on encrypted mirrored storage

Rejected because it spends redundant capacity on reacquirable data and leaves
services spanning unrelated storage policies.

### Change application paths during the split

Rejected because it adds application-state migration and client changes without
improving the storage classification.

### Keep only one bulk subtree outside secure storage

Rejected because the historical namespace would continue to describe two
different protection classes.

### Rename secure storage during the bulk cutover

Rejected because it combines data movement, mount replacement, encryption
policy, backup behavior, and rollback in one fault domain.

## Consequences

- Replaceable capacity-oriented data and secure recovery-oriented data have
  explicit, independent storage policies.
- Consumer paths remain stable.
- A single bulk branch failure can lose data and must be accepted for every
  directory classified as replaceable.
- Secure storage remains mirrored, encrypted ZFS under ADR-0064.
- The completed class split and the pending physical move remain separate
  changes.
