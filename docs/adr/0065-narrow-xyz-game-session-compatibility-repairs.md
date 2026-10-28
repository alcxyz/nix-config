# ADR-0065: Keep xyz game-session compatibility repairs narrow and event-scoped

**Status:** Accepted
**Date:** 2026-09-05
**Amended:** 2026-10-28
**History:** [replaced text](archive/0065-narrow-xyz-game-session-compatibility-repairs-history.md)
**Applies to:** `users/alc/linux/xyz.nix`, `users/alc/linux/xyz/gaming/desktop.nix`, `users/alc/linux/xyz/desktop-scripts`, `hosts/xyz/configuration.nix`, Hyprland, XWayland, DMS, Heroic

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

Powering the 49-inch output off with its button disconnects it, unlike DPMS
blanking, and the panel's care cycle runs only after such a power-off. With
the output gone, workspace 8 moves to the narrower output, where the scrolling
layout sizes a tiled Battle.net column below the launcher's minimum width.
Wine resizes the window back and the layout re-imposes its width without end:
a watcher logged hundreds of identical configure events per second, wineserver
and the launcher used up to two cores, and the embedded browser's GPU process
ran out of memory on the unread events every half hour. The browser
hardware-acceleration setting made no difference. With the window floating, the
same power-off produced two configure events and no load (#748). The same
power-off left the launcher and Wine's tray window off every output, and
reconnection could move the recentered launcher again to the output's left
edge, where it was contained but not home.

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
3. Route exact Battle.net and Heroes windows, and untitled XWayland
   `steam_app_default` (Wine) windows, silently to the unpinned gaming
   workspace 8. The routes themselves change no geometry, focus, fullscreen,
   or pointer state and do not bind the workspace to an output.
4. Float the exact Battle.net launcher window at 1600x1376, a size that fits
   every output, so a disconnect of the gaming output cannot start a resize
   loop between Wine and a tiled column.
5. Enable DMS do-not-disturb while an application from a declarative matcher
   list is running.
6. Give the Heroic Flatpak an explicit host timezone while it remains an
   available launcher.
7. Disable the compositor border only for the exact XWayland Heroes window,
   on any workspace. The floating layout fits decoration bounds into the
   work area on workspace moves; a monitor-height client plus a border is
   oversized and is shifted upward by the bottom border width. A controlled
   border-disabled workspace-move test preserved the client position and size.
   Prefer this decoration-only rule to post-move recentering, workspace
   pinning, or a compositor-wide border change. Keep display recovery separate.
8. Let the geometry guard also place launcher windows on workspace 8, through
   launcher policies kept separate from the game matchers so they do not
   enable notification suppression:
   - The Battle.net launcher centers on the gaming output, which is its home.
     It sets `returnHomeAfterDisplay`: once per display recovery, after the
     gaming output has stayed unchanged for five seconds, the guard returns
     it home even when it is contained, but only within the 90 seconds after
     that output change. A failed move is retried; the return counts once a
     move succeeds or the window is already home. Only a change of the gaming
     output itself, in its sampled state or in a compositor event that names
     it, restarts the delay and the once-only record, so display events from
     the other output do not snap a moved launcher back; the outputs have
     explicit positions, so the other output cannot shift the gaming output's
     geometry. The first sample after the guard starts arms no return, since
     startup recovery already places watched windows. A move that lands after
     the delay is left to containment recovery, which continues as before for
     the rest of the 90-second window.
   - Wine's tray window has a home offset, 16 px from the output's top-left
     corner, and keeps containment-only placement: launch and display
     recovery return it there only when it is outside the output, so
     intentional moves within the output, and contained windows that share
     its untitled identity such as popups, are left alone. The tray policy
     matches any empty-title floating Wine window on workspace 8; an untitled
     window left outside the output, from this or another prefix, shares the
     tray's home position until its title selects another policy.
9. Scope launch recovery to the windows whose identification armed it, so
   opening a game does not reset the launcher or tray. A window arms once per
   matching policy in its lifetime: one that maps untitled matches the tray
   policy, and its real title arms it again under the game's policy. Display
   recovery considers every watched window and runs alongside an active launch
   window instead of waiting for it. The service-start sweep is armed directly,
   so an early identification cannot narrow it.

The geometry guard must not change focus, workspace, floating/fullscreen state,
or pointer confinement. It must not continuously enforce window placement. The
only static Heroes of the Storm or Battle.net rules are the exact workspace-8
routes, the Battle.net launcher's floating size and the Heroes-only border
removal above. Focus, fullscreen and pointer behavior stay outside static rules.

Each measure has one responsibility and must be removable without changing the
others. New game-specific repairs require a reproduced failure and should be
introduced one layer at a time.

## Alternatives Considered

- **Remove every compatibility measure**: rejected because XWayland output
  identity and geometry can remain stale after a real output transition.
- **Restore static window, focus, fullscreen, and pointer rules**: rejected
  because they apply outside the failure window and previously interfered with
  ordinary desktop and game behavior.
- **Continuously poll and correct game windows**: rejected because it can
  fight intentional window operations and obscure the event that caused the
  invalid state.
- **Pin gaming workspaces to a monitor**: rejected as the primary repair. It
  can provide a preferred layout, but does not correct stale XWayland output
  coordinates or pointer behavior.
- **Change launchers as the display fix**: rejected. Heroic, Steam, and a
  direct UMU launcher all ultimately expose the Windows application through
  Proton and XWayland.
- **Freeze or stop Battle.net when the output disconnects**: rejected because
  it would also act on disconnects the operator did not intend as idle.
- **Give the tiled launcher a full-width column**: fits every output but makes
  it 5120 px wide on the gaming output.
- **Force the connector state to hide the disconnect**: rejected because the
  output may not recover cleanly when it powers on.
- **Police the launcher's position for the whole recovery window**: rejected;
  the operator chose a fixed home with one settled return, and a later move is
  left to containment recovery.

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
- After a change of the gaming output itself, for example a power-off and
  reconnection, the Battle.net launcher returns to the output center once per
  recovery, even if it is contained elsewhere on the output. The return
  happens only after the gaming output has stayed unchanged for five seconds,
  and only within the 90 seconds after that change; a failed move is retried
  within that window. Once the return has counted, a later move within the
  output stays put; only a launcher left outside the output is recentered,
  by containment recovery, for the rest of the 90-second window.
- The game matcher list is the shared, declarative extension point for geometry
  recovery and notification suppression; launcher policies extend only
  geometry recovery.
- The XWayland primary-output repair remains host- and output-layout-specific.
- Heroic's timezone override can be removed independently if Heroic is retired.
- Display, focus, and input behavior remain explicit QA gates for future
  launcher or compositor changes.

## Tracking

- Forgejo issue #264 records the compatibility baseline.
- Forgejo issue #267 tracks regression qualification for the direct launch path.
- Forgejo issue #748 records the floating Battle.net launcher and launcher
  placements, power-cycle qualified on 2026-10-19.
