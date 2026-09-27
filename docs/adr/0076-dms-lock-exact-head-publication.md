# ADR-0076: Validate and merge DMS lock updates at an exact head

**Status:** Accepted
**Date:** 2026-09-27
**Applies to:** `.forgejo/workflows/`, `scripts/forgejo/publish-dms-plugins-lock.sh`

## Context

The scheduled DMS updater builds the refreshed Home Manager activation package
before opening a lock-update pull request. A pull request created by its
workflow credential does not automatically run the ordinary pull-request check.
Checking for that status immediately after creating a new commit therefore
leaves every automated update open. Repeating the publisher can replace the
candidate head and invalidate any status obtained later.

## Decision

After the activation build, publish a receipt for the exact lock-only commit
and explicitly dispatch the existing development checks against that commit.
Keep an unchanged candidate head on later updater runs. A separate scheduled
merge pass requires both successful exact-head receipts, a current development
base, and a single `flake.lock` change before requesting a guarded squash merge.
It does not rewrite the pull-request branch. Missing or pending checks leave
the pull request open.

The validation run uses the same credential-free development check script as
ordinary pull requests into `dev`. Forgejo does not automatically publish a
commit status for dispatched workflows, so this run records pending before
validation and publishes a distinct success receipt only after its actual
checks pass. It does not receive the updater's source access or repeat its
full activation build. This preserves the distinction between the updater's
build receipt and the development-check receipt.

## Alternatives Considered

- **Check immediately and retry the whole updater** — the check cannot finish
  synchronously, and a new commit can discard the prior result.
- **Merge after the updater build alone** — omits the ordinary development
  checks on the committed pull-request head.
- **Use a new publication credential** — unnecessary when an explicit workflow
  dispatch can start the existing checks and a later pass can inspect results.

## Consequences

Publication may take until the next merge pass. A changed base or failed check
leaves a reviewable pull request open. Full activation validation remains tied
to the updater run; the later merge pass verifies its exact committed tree and
receipt before merging. Follow-up is tracked in
[nix-config #470](https://git.alc.xyz/alcxyz/nix-config/issues/470).
