# ADR-0076: Validate and merge DMS lock updates at an exact head

**Status:** Accepted
**Date:** 2026-09-27
**Amended:** 2026-10-28
**History:** [replaced text](archive/0076-dms-lock-exact-head-publication-history.md)
**Applies to:** `.forgejo/workflows/`, `scripts/forgejo/publish-dms-plugins-lock.sh`, `scripts/ci/run-local-dms-update.sh`, `modules/home-manager/services/nix-package-promotion/`

## Context

The DMS updater builds the refreshed Home Manager activation package before
opening a lock-update pull request. A pull request created by its workflow
credential does not automatically run the ordinary pull-request check.
Checking for that status immediately after creating a new commit therefore
leaves every automated update open. Repeating the publisher can replace the
candidate head and invalidate any status obtained later.

## Decision

### Trusted local build

The DMS updater runs as the existing trusted operator on `xyz`, using its
native persistent Nix store and ordinary Git source access. The Home Manager
module exposes an opt-in service and daily timer; `xyz` enables it. The timer
does not catch up missed runs on activation. It shares the local package
promotion lock so those native build jobs do not overlap. An optional systemd
admission condition on `xyz` starts the updater only while the existing
runner service is active. This defers a new build when that service is stopped
for gaming, pressure, or maintenance; it does not pause an already running Nix
daemon build. Daemon worker limits remain host policy.

The updater fetches only the committed `dev` head, builds the selected Home
Manager activation package, and checks the unchanged base and lock-only tree
before using the existing publisher. The publisher reads the activated status
token file and uses the operator's configured Git identity. No runner gains
host store access. The hosted `Refresh DMS plugins lock` workflow starts no
build; it only points at the local updater.

### Exact-head publication and merge

After the activation build, publish a receipt for the exact lock-only commit
and explicitly dispatch the existing development checks against that commit.
Keep an unchanged candidate head on later updater runs. A separate scheduled
merge pass, hourly, requires both successful exact-head receipts, a current
development base, and a single `flake.lock` change before requesting a
guarded squash merge. It does not rewrite the pull-request branch, and it
keeps that branch for the next candidate. Missing or pending checks leave the
pull request open.

Publication confirms the open pull request's repository and branch identity,
then records the build receipt for the locally verified pushed commit. Forgejo
can briefly report stale mergeability and revision metadata after a push; the
merge pass checks those fields against current state before merging.

The validation run uses the same credential-free development check script as
ordinary pull requests into `dev`. Forgejo does not automatically publish a
commit status for dispatched workflows, so this run records pending before
validation and publishes a distinct success receipt only after its actual
checks pass. It does not receive the updater's source access or repeat its
full activation build. This preserves the distinction between the build
receipt, `ci/dms-lock-build`, which means the candidate lock's activation
package was actually built, and the development-check receipt,
`ci/dms-lock-validation`.

## Alternatives Considered

- **Check immediately and retry the whole updater** - the check cannot finish
  synchronously, and a new commit can discard the prior result.
- **Merge after the updater build alone** - omits the ordinary development
  checks on the committed pull-request head.
- **Use a new publication credential** - unnecessary when an explicit workflow
  dispatch can start the existing checks and a later pass can inspect results.

## Consequences

Publication may take until the next merge pass. A changed base or failed check
leaves a reviewable pull request open. Full activation validation remains tied
to the local updater run; the later merge pass verifies its exact committed
tree and receipt before merging. The automation was completed and qualified in
[nix-config #470](https://git.alc.xyz/alcxyz/nix-config/issues/470), and the
local build placement in
[nix-config #476](https://git.alc.xyz/alcxyz/nix-config/issues/476).
