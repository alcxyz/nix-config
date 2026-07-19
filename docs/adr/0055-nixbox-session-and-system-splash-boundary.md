# ADR-0055: Split NIXBOX session splash from system splash

**Status:** Accepted
**Date:** 2026-07-19
**Applies to:** `hosts/xps`, `modules/nixos/services/moonlight-client`, Plymouth, Quickshell

## Context

The XPS media-center experience needs coherent NIXBOX branding during graphical
session startup and, later, during boot, reboot, and shutdown. The supplied
design handoff contains reusable artwork and motion direction, but its HTML
captures are not reproducible runtime components and two reference images were
captured after their animations had faded to a blank frame.

DMS is intentionally started after the compositor and owns persistent desktop
shell behavior. Making the startup splash a DMS plugin would delay it, couple it
to the merged profile, and make DMS restart policy part of a short-lived visual.
Plymouth, in contrast, runs before the user session and has different rendering,
display, and failure constraints.

## Decision

Implement two independent renderers that share the same visual assets and
timing vocabulary:

- a standalone Quickshell session splash launched before the couch browser;
- one Plymouth script theme for boot, reboot, and shutdown, selected through
  Plymouth's runtime mode.

Deliver and validate the session splash first. It must render on every active
output, use one process-wide animation epoch, avoid keyboard and pointer focus,
and terminate through both its normal animation deadline and a hard watchdog.
Display hotplug may add or remove a surface without restarting the animation.
Failure to launch or finish the splash must never block the browser, DMS, or the
Hyprland session.

Keep the compositor background aligned with the splash background so that slow
applications and display relayout do not expose a bright transition. Preserve
asset licensing and attribution in the packaged output.

Add Plymouth only after the session implementation has been validated on the
real display combinations. Enable early Intel KMS as part of that stage and do
not make greetd, hyprlock, DMS theming, or stream transitions part of this
decision.

## Consequences

Session branding remains available in couch profiles that run DMS and those
that do not. A DMS restart cannot replay the splash, and a splash failure cannot
take down the desktop shell.

The two renderers require small parallel implementations because Plymouth and
Qt Quick do not share an animation runtime. Reusing assets, fixed wordmark
geometry, colors, and timing keeps the visible result coherent without forcing
an unreliable cross-runtime abstraction.

## Tracking

- Issue #157 tracks the session implementation and later Plymouth rollout.
