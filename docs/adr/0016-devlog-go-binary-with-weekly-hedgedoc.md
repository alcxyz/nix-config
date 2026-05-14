# ADR-0016: Devlog as Go binary with weekly summaries and HedgeDoc posting

**Status:** Accepted
**Date:** 2026-04-25
**Applies to:** `modules/home-manager/services/devlog/`, `nix-packages/tools/devlog/`

## Context

The automated devlog system initially ran as bash scripts (`devlog.sh`, `weekly-devlog.sh`) in the journal repo. The daily script was invoked by a systemd timer at 23:00 for the current day, leaving a gap between 23:00 and midnight where activity was missed. The scripts also needed to duplicate their dependency list between the script PATH and the systemd service Environment.

A weekly summary was requested to improve readability — synthesizing daily entries into a higher-level narrative with weekday/weekend separation, and posting it to HedgeDoc for browsing outside git.

## Decision

1. **Go binary in nix-packages**: The devlog tool is a single Go binary (`devlog daily` / `devlog weekly` / `devlog catch-up`) in `nix-packages/tools/devlog/`, built with `buildGoModule` and exposed via the overlay as `pkgs.devlog`. This follows the same pattern as `zfs-auto-unlock`.

2. **Schedule shift and catch-up**: Daily timer runs at 01:00 and invokes `devlog catch-up`, which scans a configurable recent window (`services.devlog.catchUpDays`, default 30) through yesterday. This preserves the 01:00 "yesterday" semantics while filling holes from host or timer outages.

3. **Weekly timer**: Runs Monday at 02:00 (after Sunday's daily entry is generated at 01:00). Produces `weekly/YYYY-WNN.md` with ISO week numbering and posts to HedgeDoc via sops-decrypted credentials. The weekly file contains a Claude-synthesized summary (split into distinct **Weekdays** and **Weekend** sections) followed by all raw daily entries stitched below a `# Daily entries` heading, so the full week is readable in one file.

4. **Module structure**: The NixOS module uses `lib.mkMerge` to conditionally add the weekly service/timer when `services.devlog.weekly.enable` is set, keeping weekly as an opt-in extension of the daily system.

## Alternatives Considered

- **Keep as shell scripts**: Works, but no build-time checking, duplicated PATH/dependency management between script and systemd unit, harder to extend.
- **Nix `writeShellApplication`**: Would give shellcheck and declared `runtimeInputs`, but doesn't match the existing Go tool pattern in this ecosystem and is harder to test interactively.
- **Separate module for weekly**: Rejected because weekly depends on daily entries existing and shares config (repoPath). Nesting under `services.devlog.weekly` is cleaner.

## Consequences

- The journal repo no longer contains any scripts — it is purely data (daily/weekly markdown files).
- Daily generation is outage-tolerant for short host downtime: missed days in the catch-up window are generated on the next successful timer run.
- Weekly files are self-contained: the summary provides the narrative, and the stitched daily entries provide the detail, eliminating the need to open individual daily files.
- Weekly summaries for completed weeks are refreshed when catch-up creates a missing daily entry in that week.
- The `devlog` binary must be in the nix-packages overlay for the systemd service to reference it as `pkgs.devlog`.
- HedgeDoc credentials are decrypted at runtime via sops in the Go binary; the systemd service needs `sops` and `age` in PATH plus `SOPS_AGE_KEY_FILE` set.
