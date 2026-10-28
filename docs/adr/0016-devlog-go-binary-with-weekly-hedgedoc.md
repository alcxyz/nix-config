# ADR-0016: Devlog as Go binary with weekly summaries

**Status:** Accepted
**Date:** 2026-04-25
**Amended:** 2026-10-28
**History:** [replaced text](archive/0016-devlog-go-binary-with-weekly-hedgedoc-history.md)
**Applies to:** `modules/home-manager/services/devlog/`, `nix-packages/tools/devlog/`

## Context

The automated devlog system initially ran as bash scripts (`devlog.sh`, `weekly-devlog.sh`) in the journal repo. The daily script was invoked by a systemd timer at 23:00 for the current day, leaving a gap between 23:00 and midnight where activity was missed. The scripts also needed to duplicate their dependency list between the script PATH and the systemd service Environment.

A weekly summary was requested to improve readability by synthesizing daily entries into a higher-level narrative with weekday/weekend separation.

Most of the user's work is Forgejo-first, and GitHub search missed most of it:
forge squash merges carry an identity GitHub does not link to the account, and
Forgejo pull requests and issues were never seen. devlog also first wrote into
the private journal checkout, which is edited by hand; since devlog refuses to
run on a dirty tree, a run could fail just because someone was working there.

## Decision

1. **Go binary in nix-packages**: The devlog tool is a single Go binary (`devlog daily` / `devlog weekly` / `devlog catch-up`) in `nix-packages/tools/devlog/`, built with `buildGoModule` and exposed via the overlay as `pkgs.devlog`. This follows the same pattern as `zfs-auto-unlock`.

2. **Schedule shift and catch-up**: Daily timer runs at 05:00 (`services.devlog.schedule`) and invokes `devlog catch-up`, which scans a configurable recent window (`services.devlog.catchUpDays`, default 30) through the last completed devlog day. A devlog day is the local-time window from 05:00 through 04:59 the next calendar day, so late-night activity stays attached to the previous day's entry while host or timer outages are backfilled.

3. **Weekly timer**: Runs Monday at 06:00 (`services.devlog.weekly.schedule`, after Sunday's daily entry is generated at 05:00). Produces `weekly/YYYY-WNN.md` with ISO week numbering. The weekly file contains an LLM-synthesized summary (split into distinct **Weekdays** and **Weekend** sections) followed by all raw daily entries stitched below a `# Daily entries` heading, so the full week is readable in one file.

4. **Module structure**: The Home Manager module uses `lib.mkMerge` to conditionally add the weekly service/timer when `services.devlog.weekly.enable` is set, keeping weekly as an opt-in extension of the daily system.

5. **Activity sources**: Forgejo is the primary activity source. devlog reads
   the user's Forgejo activity feed (`services.devlog.forgejo`, token through a
   `*_FILE` variable) and keeps GitHub for GitHub-native repositories, removing
   commits already seen through mirrors.

6. **All repositories the user works in are included.** The devlog is private
   and records the user's own work, so activity in repositories owned by others
   (forks, third-party projects, employers) is treated like any other and its
   diffs are summarised in full.

7. **Entries live in their own private repository.** Generated entries live in
   a dedicated repository that devlog clones on first run
   (`services.devlog.repoUrl`) into a checkout under the XDG state directory
   (`services.devlog.repoPath`) that nobody edits by hand. The entries were
   moved there from the journal with their history on 2026-10-05.

8. **A deploy key for pushes**: `services.devlog.sshKeyFile` points git at a
   private key, and the units then ignore the SSH agent and the user's ssh
   config, so no personal key is offered. On xyz it is a write deploy key
   limited to the entries repository (`alcxyz/devlog`), wired from the private
   flake like the other generated sources' keys
   ([#805](https://git.alc.xyz/alcxyz/nix-config/issues/805)). Forgejo records
   deploy-key pushes as the repository owner, so that repository's publish
   step, which accepts only the owner's pushes, keeps working. Null keeps the
   agent.

9. **No HedgeDoc publishing**: The Git-backed weekly Markdown file is the
   canonical, browsable artifact. devlog does not post weekly files as HedgeDoc
   notes: no journal workflow linked back to the generated notes, and
   regenerated weeks could leave stale duplicate notes. HedgeDoc remains
   available for collaborative Markdown documents, but is not part of devlog
   delivery.

## Alternatives Considered

- **Keep as shell scripts**: Works, but no build-time checking, duplicated PATH/dependency management between script and systemd unit, harder to extend.
- **Nix `writeShellApplication`**: Would give shellcheck and declared `runtimeInputs`, but doesn't match the existing Go tool pattern in this ecosystem and is harder to test interactively.
- **Separate module for weekly**: Rejected because weekly depends on daily entries existing and shares config (repoPath). Nesting under `services.devlog.weekly` is cleaner.
- **Push through the operator's SSH agent**: the original behaviour. A run
  depended on the agent being loaded and used the operator's personal key,
  which reaches every repository. Kept only as the fallback when
  `sshKeyFile` is null.

## Consequences

- The journal repo contains no devlog scripts or generated entries; it stays hand-edited.
- A hand edit in the journal can no longer make a devlog run fail on a dirty tree.
- Daily generation is outage-tolerant for short host downtime: missed days in the catch-up window are generated on the next successful timer run.
- Weekly files are self-contained: the summary provides the narrative, and the stitched daily entries provide the detail, eliminating the need to open individual daily files.
- Weekly summaries for completed weeks are refreshed when catch-up creates a missing daily entry in that week.
- Pushes from xyz do not depend on a loaded SSH agent and cannot reach repositories other than the entries repository.
- The `devlog` binary must be in the nix-packages overlay for the systemd service to reference it as `pkgs.devlog`.
