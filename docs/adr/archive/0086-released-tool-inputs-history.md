**History of** [ADR-0086](../0086-released-tool-inputs.md): text replaced on 2026-10-28 and 2026-10-30.

# ADR-0086: Refresh released platform tools with tools-update

**Status:** Accepted, amended by [ADR-0087](../0087-side-by-side-dev-tools.md) (dev builds side by side with `dev-tools-update`). Tools hosted on GitHub, such as t3rry, pin `github:alcxyz/<repo>/main` instead of a Forgejo `?ref=main` URL. The list has since gained t3rry and hedgedoc; `scripts/update-inputs/update-tools.sh` is the current list. hedgedoc's CLI is exposed as `pkgs.hedgedoc-cli`, because nixpkgs' `hedgedoc` is the server
**Date:** 2026-10-09
**Applies to:** `flake.nix`, `scripts/update-inputs/update-tools.sh`, `users/alc/common.nix`, `justfile`; amends ADR-0069

## Context

The owner's own command-line tools reached the workstation in different ways.
paperweight (paperless-tools) was a flake input on `main` that was refreshed only
by naming it to `nix flake update`. reportcraft, stashdb-pop and videdupe followed
their default branch. bokfor (regnskap) was not packaged: it ran from the regnskap
checkout, at whatever branch that checkout had. `apps-update` (ADR-0069) covers
only the dev-branch QA apps and the DMS plugins, so nothing kept the tools
current. Unlike the QA apps, these tools do real work against the archive and
the accounts, so they should run released code.

## Decision

`tools-update` (a shell alias, also `just tools-update`) refreshes one explicit
list of tool inputs: paperless-tools, regnskap, reportcraft, stashdb-pop and
videdupe. Each follows its repository's released `main` branch, written
explicitly as `?ref=main`. As with `apps-update`, the command only changes
`flake.lock`; the owner inspects the change and activates it with `hmsw`. The two
lists do not overlap.

regnskap provides a flake package for bokfor at its `VERSION` release, and xyz
installs it next to paperweight. The documented workflow still runs it from
the checkout's `cmd/bokfor` directory (`direnv exec . bokfor …`), which holds
its environment and configuration. The `bokfor-dev` launcher keeps running a checkout against the
sandbox.

A tool joins the list when its repository releases from `main` and has a flake
package. vidown stays on its current pin for now, because its `main` is far
behind `dev`. Services such as Timebank and the deployed bokfor-admin keep
their own deployment paths.

## Alternatives and consequences

- **Add the tools to `apps-update`:** this mixes released tools with dev QA pins
  and changes what `apps-update` means.
- **Keep running bokfor from the checkout:** its version then depends on
  whichever branch another task left checked out.
- **Follow `dev` for the tools as well:** daily bookkeeping would run unreleased
  code. Dev builds are installed side by side instead (ADR-0087).

A tool's flake must keep building at `main`. For Go tools, a stale `vendorHash`
after a dependency change breaks the next build after `tools-update`; the
previous lock and generation remain the rollback.

## Text replaced on 2026-10-30

From the status block:

  **Amended:** 2026-10-28, updated 2026-10-29 (devstats added to the tool list, per owner decision)

From the decision, the tool list:

  `tools-update` (a shell alias, also `just tools-update`) refreshes one explicit
  list of tool inputs, each following its repository's released `main` branch:
  paperless-tools, regnskap, reportcraft, stashdb-pop, videdupe, t3rry, hedgedoc
  and devstats.

videdupe was removed from nix-config: vidown ADR-023 moved its duplicate review
into vidown, which `dev-apps-update` refreshes (ADR-0089).
