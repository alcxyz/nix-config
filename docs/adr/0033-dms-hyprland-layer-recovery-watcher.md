# ADR-0033: DMS Hyprland layer recovery watcher

**Status:** Accepted
**Date:** 2026-05-03
**Applies to:** `modules/home-manager/programs/hyprland/scripts/dms_resume_watcher.sh`, `users/alc/configs/hypr/hyprland.conf`

## Context

On `xyz`, DankMaterialShell runs as a Quickshell layer-shell client under Hyprland. After the monitor enters DPMS sleep and wakes again, DMS can remain alive while one or more layer surfaces stop behaving correctly. The usual symptom is that overlays or OSD surfaces no longer appear, even though the `dms` and `quickshell` processes are still running.

Earlier fixes tried progressively different triggers:

- system resume via `org.freedesktop.login1.Manager.PrepareForSleep`
- Hyprland socket2 `dpms>>on`
- Hyprland layer events such as `openlayer>>dms:bar` and `closelayer>>dms:bar`

Those triggers were incomplete. Plain monitor DPMS sleep does not always emit system sleep signals, and the DMS layer can fail in a state where the expected reopen event never arrives.

## Decision

Keep DMS launched from Hyprland `exec-once`, and run a companion `dms_resume_watcher.sh` process from the same session.

The watcher treats display sleep and wake as state, not as a single socket event. It arms itself when:

- Hyprland reports no awake monitor via `hyprctl monitors -j`
- socket2 emits `dpms>>off`
- socket2 emits `monitorremoved`
- socket2 emits `closelayer>>dms:bar` while Hyprland does not report an awake monitor

Once armed, it waits until Hyprland reports a live, enabled, DPMS-on monitor for two stable checks. For plain display sleep it then restarts DMS once, using `dms kill` plus a targeted fallback `pkill`, and relaunches `dms run`.

For display sleep caused by the external Hyprlock wrapper, it waits until Hyprlock exits, gives the compositor a short settle window, and checks whether DMS layer namespaces are present again. If they are present, it skips the restart so the wallpaper background layer is not torn down during unlock recovery. If the DMS layers are still absent, it restarts DMS as the recovery fallback.

## Alternatives Considered

- **Run DMS under its Home Manager systemd user service** — Rejected for now. The available unit supervises the process, but the failure mode is not just process death; DMS can remain alive while layer surfaces are broken after DPMS wake.
- **Restart only on `PrepareForSleep=false`** — Rejected. Monitor DPMS sleep is not system suspend and does not reliably emit this signal.
- **Restart only on `dpms>>on`** — Rejected. Previous attempts showed this was not enough across Hyprland/DMS failure modes.
- **Restart only on layer reopen events** — Rejected. Waiting for `openlayer>>dms:bar` has a chicken-and-egg problem when the DMS layer never successfully reopens.
- **Always restart DMS on any layer close** — Rejected. This is noisy and can self-trigger during the watcher-initiated restart.

## Consequences

- DMS overlay recovery is tied to Hyprland's actual monitor state instead of one fragile event.
- The watcher remains Hyprland-specific and should not be reused for Niri without a separate compositor-specific implementation.
- DMS still restarts after plain monitor wake, so transient shell state may reset.
- Hyprlock-driven wake avoids a DMS restart when DMS layers have already recovered, preserving wallpaper recovery across unlock.
- The cooldown and two stable monitor checks reduce restart loops, but future Hyprland or Quickshell changes may require adjusting the watched events.
