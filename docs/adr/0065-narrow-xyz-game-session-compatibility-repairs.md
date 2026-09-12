# ADR-0065: Keep xyz game-session compatibility repairs narrow and event-scoped

**Status:** Accepted
**Date:** 2026-09-05
**Applies to:** `users/alc/linux/xyz.nix`, `hosts/xyz/configuration.nix`, Hyprland, XWayland, DMS, Heroic

## Context

The `xyz` desktop combines a vertically arranged multi-monitor Hyprland layout
with XWayland games. Output power transitions and topology changes can leave an
XWayland game with stale output coordinates or an unsuitable XWayland primary
output. Notifications can also interrupt a game session, while a sandboxed
launcher may expose a timezone that differs from the host.

Earlier experiments accumulated overlapping window rules, focus repairs,
workspace placement, pointer confinement, and continuous polling. Those layers
were difficult to reason about and sometimes changed normal workspace, focus,
or pointer behavior. Removing every compatibility measure was also insufficient:
the output-transition geometry failure remained reproducible.

## Decision

Retain only five independent compatibility measures:

1. Keep the 49-inch gaming output selected as XWayland's primary output, with
   an event-driven repair when the output layout changes.
2. Use an event-scoped geometry guard for explicitly matched games. Center a
   newly identified game for ten seconds. Independently sample the gaming
   output's availability and geometry once per second, since display power
   transitions need not emit socket events. When the output returns or its
   geometry changes, arm a separate 90-second containment/vertical-edge repair
   window. Do not repeatedly center an already-contained window during this
   longer window. Apply repairs only while the game's dedicated workspace is
   on the gaming output. Preserve size, ignore repeated title notifications
   for an already identified window, and leave other workspaces alone.
3. Route exact Battle.net and Heroes windows silently to the unpinned gaming
   workspace 8. This rule changes no geometry, focus, fullscreen, or pointer
   state and does not bind the workspace to an output.
4. Enable DMS do-not-disturb while an application from a declarative matcher
   list is running.
5. Give the Heroic Flatpak an explicit host timezone while it remains an
   available launcher.

The geometry guard must not change focus, workspace, floating/fullscreen state,
or pointer confinement. It must not continuously enforce window placement. The
only static Heroes of the Storm or Battle.net rules are the exact workspace-8
routes above.

Each measure has one responsibility and must be removable without changing the
others. New game-specific repairs require a reproduced failure and should be
introduced one layer at a time.

## Alternatives Considered

- **Remove every compatibility measure** — Rejected because XWayland output
  identity and geometry can remain stale after a real output transition.
- **Restore static window, focus, fullscreen, and pointer rules** — Rejected
  because they apply outside the failure window and previously interfered with
  ordinary desktop and game behavior.
- **Continuously poll and correct game windows** — Rejected because it can
  fight intentional window operations and obscure the event that caused the
  invalid state.
- **Pin gaming workspaces to a monitor** — Rejected as the primary repair. It
  can provide a preferred layout, but does not correct stale XWayland output
  coordinates or pointer behavior.
- **Change launchers as the display fix** — Rejected. Heroic, Steam, and a
  direct UMU launcher all ultimately expose the Windows application through
  Proton and XWayland.

## Consequences

- Normal focus, workspace switching, fullscreen toggling, and pointer behavior
  remain under Hyprland and the game rather than a stack of game rules.
- Recovery is limited to the display/session transition where stale geometry
  is expected and the initial game-window identification. Launching a game
  long after wake must not miss recovery merely because the launcher stayed
  open. Workspace routing alone cannot repair stale client coordinates.
- Output-state sampling is continuous, but window correction is not. Failed
  monitor queries are unknown state, not synthetic disconnect/reconnect events.
  A launch event cannot shorten an active display-recovery deadline.
- The game matcher list is the shared, declarative extension point for geometry
  recovery and notification suppression.
- The XWayland primary-output repair remains host- and output-layout-specific.
- Heroic's timezone override can be removed independently if Heroic is retired.
- Display, focus, and input behavior remain explicit QA gates for future
  launcher or compositor changes.

## Tracking

- Forgejo issue #264 records the compatibility baseline.
- Forgejo issue #267 tracks regression qualification for the direct launch path.
