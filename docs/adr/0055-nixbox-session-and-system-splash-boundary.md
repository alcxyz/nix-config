# ADR-0055: Keep the NIXBOX splash at the graphical-session boundary

**Status:** Accepted
**Date:** 2026-07-19
**Applies to:** `hosts/xps`, `modules/nixos/services/moonlight-client`, Quickshell

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

Keep the normal NixOS boot console visible. Plymouth was tested on the firmware
framebuffer, with early Intel and Thunderbolt KMS, and after settling the
external connector topology. On this hardware the animation timeline still ran
before the active external output became usable, then appeared late and added
black frames, mode switches, and a misleading empty progress bar. Delaying
Plymouth until the outputs settled merely prolonged the visible console phase.

Begin NIXBOX branding only after Hyprland owns a usable output. A standalone
Quickshell overlay identifies the graphical session and fades into the couch
desktop. Power-off and reboot reverse the motion before DMS requests the system
action. The Quickshell component must render on every active output, use one
process-wide animation epoch, avoid keyboard and pointer focus, and terminate
through both its normal animation deadline and a hard watchdog. Display hotplug
may add or remove a surface without restarting the animation. Failure to launch
or finish the splash must never block the browser, DMS, or the Hyprland session.

Keep the compositor background aligned with the splash background so that slow
applications and display relayout do not expose a bright transition. Preserve
asset licensing and attribution in the packaged output.

Keep the normal boot verbosity rather than using a quiet kernel command line.
This preserves visible diagnostics and avoids a long, uninformative black boot.
Retain the now-proven early Intel and Thunderbolt module inventory so the
diagnostic console can reach external displays; do not narrow the host's
known-good initrd hardware module set for branding.

## Consequences

Session branding remains available in couch profiles that run DMS and those
that do not. A DMS restart cannot replay the splash, and a splash failure cannot
take down the desktop shell.

Boot remains diagnosable and does not depend on early graphical output routing.
The existing userspace display-pipeline service still applies the
three-external/internal-panel fallback policy before greetd; the dynamic
Hyprland layout continues to own output selection, workspaces, and mirroring.
User-initiated power actions keep their coherent transition while the
compositor owns the outputs; emergency and non-graphical shutdown paths remain
unbranded and diagnosable.

## Tracking

- Issue #157 tracks the session implementation and the rejected Plymouth trial.
