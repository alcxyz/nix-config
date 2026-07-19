# ADR-0055: Stage the NIXBOX splash across boot and graphical session

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

Implement the three distinct transitions from the design handoff:

- Plymouth assembles the boot wordmark from one overlapped X, separates the two
  X positions, reveals the remaining letters and `MEDIA CENTER`, fills the
  progress track, and raises the Nix watermark behind the lockup.
- A standalone Quickshell overlay begins only after Hyprland owns a usable
  output and presents `STARTING SESSION` without a progress bar.
- Power-off and reboot reverse the wordmark motion while the compositor still
  owns the outputs, before DMS requests the system action.

Load the Intel and Thunderbolt display path in the initrd, but do not delay
Plymouth while waiting for a preferred connector topology. The script plugin's
display-hotplug callback rebuilds scaled sprites for the current virtual canvas
and restarts only an unfinished intro when the firmware surface is replaced by
real KMS outputs. Once the assembled lockup is visible, later connector events
must not reset the animation.

Prefer Plymouth's measured boot estimate for the progress fill. When no timing
estimate is available, use the approved design prototype's bounded fill curve
so the final lockup cannot remain empty; the quit frame is always complete. The
watermark opacity follows the handoff's progress formula and reaches at most
five percent.

The Quickshell component must render on every active output, use one
process-wide animation epoch, avoid keyboard and pointer focus, and terminate
through both its normal animation deadline and a hard watchdog. Display hotplug
may add or remove a session surface without restarting its animation. Failure
to launch or finish the session splash must never block the browser, DMS, or the
Hyprland session.

Keep the compositor background aligned with the splash background so that slow
applications and display relayout do not expose a bright transition. Preserve
asset licensing and attribution in the packaged output.

Keep the normal boot verbosity rather than using a quiet kernel command line so
diagnostics remain logged and Plymouth's details view can expose them. Retain
the proven initrd module inventory; do not narrow the host's hardware module set
for branding.

## Consequences

Session branding remains available in couch profiles that run DMS and those
that do not. A DMS restart cannot replay the splash, and a splash failure cannot
take down the desktop shell.

The early boot renderer adapts to the pixel displays Plymouth actually exposes;
it does not encode a preferred TV or monitor. The existing userspace
display-pipeline service still applies the three-external/internal-panel
fallback policy before greetd, while Hyprland continues to own dynamic output
selection, workspaces, and mirroring.

Boot, session start, and graphical power actions retain separate renderer
lifecycles and meanings. A DMS restart cannot replay either startup animation,
and the session animation does not pretend to represent boot progress.

## Tracking

- Issue #157 tracks the staged boot and session implementation.
