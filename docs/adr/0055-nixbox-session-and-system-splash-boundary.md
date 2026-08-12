# ADR-0055: Stage the NIXBOX splash across boot and graphical session

**Status:** Accepted
**Date:** 2026-07-19
**Applies to:** Nixbox clients, `modules/nixos/services/moonlight-client`, Quickshell

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
  X positions, reveals the remaining letters, fades in a compact Nix snowflake
  beneath the wordmark, and fills the progress track below it.
- A standalone Quickshell overlay begins only after Hyprland owns a usable
  output and presents `STARTING SESSION` without a progress bar.
- Power-off and reboot reverse the wordmark motion while the compositor still
  owns the outputs, before DMS requests the system action.

Load the Intel and Thunderbolt display path in the initrd, but do not delay
Plymouth while waiting for a preferred connector topology. The script plugin's
display-hotplug callback rebuilds scaled sprites for the current virtual canvas
without changing the animation epoch. After the existing display-pipeline
allocator has allowed dock authorization and connector discovery to settle, a
boot-only oneshot uses Plymouth's supported theme reload operation to give the
visible pixel displays a deliberate frame-zero start. Before that signal, the
theme holds a static Nix/X prelude rather than exposing an arbitrary late frame.
The oneshot sends explicit start and completion stage messages around the
bounded sequence. Plymouth reliably owns a centered-X to NIXBOX letter motion
on this external KMS path. After the wordmark forms, show a compact pre-rendered
Nix snowflake below it and a simple bounded progress track below the mark. Do
not scale the multi-megapixel artwork during early boot: the large transparent
sprite was unreliable across the simpledrm-to-i915 and multi-head handoff.
Plymouth also invokes the theme's quit callback during reload, so the complete
wordmark, mark, and bar are gated on the completion signal and cannot flash
ahead of the intro.

Treat the progress fill as a bounded visual transition, not as a percentage
contract for system boot. Plymouth's refresh-driven script API permits its
intermediate cadence to differ between renderers; the explicit completion
signal provides the stable final state without extending the boot deadline.

The Quickshell component must render on every active output, use one
process-wide animation epoch, avoid keyboard and pointer focus, and terminate
through both its normal animation deadline and a hard watchdog. Display hotplug
may add or remove a session surface without restarting its animation. Failure
to launch or finish the session splash must never block the browser, DMS, or the
Hyprland session.

Keep the compositor background aligned with the splash background so that slow
applications and display relayout do not expose a bright transition. Preserve
asset licensing and attribution in the packaged output.

Retain Plymouth's completed framebuffer while greetd starts. Keep greetd's TTY
reset and hangup behavior, but do not deallocate the VT because that operation
explicitly clears the retained frame. Hyprland replaces it when the compositor
claims the output; a brief hardware mode set may still be visible.

Keep the normal boot verbosity rather than using a quiet kernel command line so
diagnostics remain logged and Plymouth's details view can expose them. Retain
the proven initrd module inventory; do not narrow the host's hardware module set
for branding.

Reuse the theme and compositor transitions on compact Nixbox clients. A client
with a direct display path uses Plymouth's normal lifecycle; it must not inherit
the XPS-only dock discovery, theme replay, or multi-output allocation services.
The generic profile keeps its display fallback and boot generation as the
recovery boundaries.

## Consequences

Session branding remains available in couch profiles that run DMS and those
that do not. A DMS restart cannot replay the splash, and a splash failure cannot
take down the desktop shell.

The early boot renderer adapts to the pixel displays Plymouth actually exposes;
it does not encode a preferred TV or monitor. The existing userspace
display-pipeline service still applies the three-external/internal-panel
fallback policy before the visible theme epoch and greetd, while Hyprland
continues to own dynamic output selection, workspaces, and mirroring. The
deliberate visible epoch adds at most eight seconds to graphical startup when
Plymouth is active, in exchange for avoiding an off-screen animation that only
exposes its final frame after a dock display appears. Plymouth does not expose a
monotonic clock to script themes, so smooth intermediate motion remains
refresh-driven while the externally signalled final frame is wall-clock bound.
Systemd-boot materializes only the newest six configurations on the EFI system
partition. Nix profile generations remain available, while stale copied
kernels and initrds cannot crowd out a newly selected boot generation.

Boot, session start, and graphical power actions retain separate renderer
lifecycles and meanings. A DMS restart cannot replay either startup animation,
and the session animation does not pretend to represent boot progress.

## Tracking

- Closed issue #157 records the accepted boot, session, reboot, and shutdown
  implementation. Further timing changes are optional visual polish.
