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

Retain the following independent compatibility measures:

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
6. Disable the compositor border only for the exact XWayland Heroes window,
   on any workspace. The floating layout fits decoration bounds into the
   work area on workspace moves; a monitor-height client plus a border is
   oversized and is shifted upward by the bottom border width. A controlled
   border-disabled workspace-move test preserved the client position and size.
   Prefer this decoration-only rule to post-move recentering, workspace
   pinning, or a compositor-wide border change. Keep display recovery separate.

The geometry guard must not change focus, workspace, floating/fullscreen state,
or pointer confinement. It must not continuously enforce window placement. The
only static Heroes of the Storm or Battle.net rules are the exact workspace-8
routes and the Heroes-only border removal above.

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

## Amendment 2026-10-19: floating Battle.net launcher and home placements (#748)

Powering the 49-inch output off with its button disconnects it, unlike DPMS
blanking, and the panel's care cycle runs only after such a power-off. With
the output gone, workspace 8 moves to the narrower output, where the scrolling
layout sizes the tiled Battle.net column below the launcher's minimum width.
Wine resizes the window back and the layout re-imposes its width without end:
a watcher logged hundreds of identical configure events per second, wineserver
and the launcher used up to two cores, and the embedded browser's GPU process
ran out of memory on the unread events every half hour. The browser
hardware-acceleration setting made no difference. With the window floating, the
same power-off produced two configure events and no load.

The decision therefore changes in two places:

- **Static rule.** Besides its workspace-8 route, the exact Battle.net window
  floats at 1600x1376, a size that fits every output. This replaces the
  statement that the workspace route is the only static Battle.net rule. Focus,
  fullscreen and pointer behavior stay outside static rules, and Heroes keeps
  only its route and border removal.
- **Launcher placements.** The geometry guard also watches the launcher window
  and Wine's tray window on workspace 8, which returned off every output after
  the power-off. These launcher policies are separate from the game matchers,
  so they do not enable notification suppression. The launcher centers on the
  gaming output. The tray window has a home offset, 16 px from the output's
  top-left corner. Launch and display recovery return it there only when it
  is outside the output, so intentional moves within the output, and
  contained windows that share its untitled identity such as popups, are
  left alone.
- **Scoped launch recovery.** With several watched windows, launch recovery
  acts only on the windows whose identification armed it, so opening a game
  no longer resets the launcher or tray. A window arms once per matching
  policy in its lifetime: one that maps untitled matches the tray policy, and
  its real title arms it again under the game's policy. Display recovery
  still considers every watched window, and now runs alongside an active
  launch window instead of waiting for it. The service-start sweep is armed
  directly, so an early identification cannot narrow it.

Alternatives considered: freezing or stopping Battle.net when the output
disconnects, rejected because they would also act on disconnects the operator
did not intend as idle; giving the tiled launcher a full-width column, which
fits every output but makes it 5120 px wide on the gaming output; and a forced
connector state that hides the disconnect, rejected because the output may not
recover cleanly when it powers on. The tray policy matches any empty-title
floating Wine window on workspace 8, which that workspace already receives; an
untitled window left outside the output, from this or another prefix, would
share the tray's home position until its title selects another policy.
