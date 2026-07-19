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

Split boot into renderer-owned stages. Plymouth renders a short intro on the
early DRM surface, holds the completed NIXBOX composition while a loading bar
advances from completed systemd boot units and Plymouth's monotonic real-root
timing estimate, and leaves one completed frame when the daemon exits. The
progress bar must not advance from an animation timeline or claim to map
one-to-one to console messages.

Load the Intel display and Thunderbolt modules in the initrd so Plymouth can
discover the real external connector set before normal userspace. Plymouth's
multi-head renderer presents the same centered composition on every active DRM
output; it must not encode a preferred TV or monitor. This changes early driver
availability only. Hyprland retains full ownership of dynamic output selection,
layout, workspaces, mirroring, and internal-panel fallback after login.

Apply the three-external/internal-fallback pipeline decision in the initrd after
the early drivers settle and before Plymouth starts. Retain the userspace
pipeline service only as a fallback when fewer than three external connectors
were visible early. This prevents a normal three-display boot from changing the
connector topology immediately before Plymouth exits.

After Hyprland owns the displays, a standalone Quickshell overlay begins from
the same completed composition, changes the subtitle to identify the graphical
session, and fades away. Power-off and reboot reverse the motion before DMS
requests the system action; the later Plymouth power units remain disabled so
the transition is not played twice. The Quickshell component must render on
every active output, use one process-wide animation epoch, avoid keyboard and
pointer focus, and terminate through both its normal animation deadline and a
hard watchdog. Display hotplug may add or remove a surface without restarting
the animation. Failure to launch or finish the splash must never block the
browser, DMS, or the Hyprland session.

Keep the compositor background aligned with the splash background so that slow
applications and display relayout do not expose a bright transition. Preserve
asset licensing and attribution in the packaged output.

Keep the normal boot verbosity rather than using a quiet kernel command line.
This preserves logged diagnostics and Plymouth's details view while allowing
the graphical view to replace the scrolling console during the normal path.
Do not narrow or otherwise modify the host's known-good initrd hardware module
set to improve splash timing.

## Consequences

Session branding remains available in couch profiles that run DMS and those
that do not. A DMS restart cannot replay the splash, and a splash failure cannot
take down the desktop shell.

Plymouth owns only the early boot surface; it releases DRM while retaining its
last pixels so the compositor can replace them. An output may remain blank until
its early driver and link are ready, but the visible intro begins only after the
connector topology settles. Boot does not wait indefinitely for a disconnected
dock. User-initiated power actions gain a coherent transition while the
compositor still owns the outputs; emergency and non-graphical shutdown paths
remain unbranded and diagnosable.

Early KMS enlarges the initrd with the Intel display driver, its dependencies
and firmware, and the Thunderbolt driver. It does not remove any generated
hardware module, and the resulting system closure outside the initrd remains
unchanged.

## Tracking

- Issue #157 tracks the staged boot and session implementation.
