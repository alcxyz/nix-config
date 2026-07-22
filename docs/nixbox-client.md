# Compact Nixbox client

`services.nixbox-client` is the reusable, small-host counterpart to the XPS
media-center workbench. It composes the existing Moonlight client rather than
forking its launch, input, audio, or recovery logic.

## Included experience

- a controller-first Hyprland session with remote Steam and browser streams;
- a compact, auto-hiding DMS shell with idle locking and suspension disabled;
- KDE Connect keyboard, pointer, click, and scrolling support through the
  XWayland/Hyprland bridge;
- LAN-only Waynergy input from a Synergy server, using uinput so input follows
  the same path as physical keyboards and pointers;
- the Nixbox Plymouth boot theme and compositor-owned session, reboot, and
  shutdown transitions;
- selectable local display audio and a local sound-system output;
- a local terminal as a maintenance escape hatch; and
- a preferred output mode with a 1080p fallback.

The profile deliberately does not include local browsers, protected profiles,
developer tools, multiple-display workspace policy, or the XPS dock-specific
Plymouth replay service. Browser state and rendering live on the remote stream
host.

## Configuration boundary

The public profile owns generic behavior and exposes options for the session
user, output mode and scale, Moonlight package, and optional presentation and
input features. Host-specific display quirks, private endpoints, credentials,
and pairing state remain outside this repository or in runtime state.

The client defaults Moonlight to XWayland because KDE Connect and Waynergy need
the proven XTest-to-Hyprland pointer bridge. Hardware video decoding remains a
property of the selected Moonlight package and is independent of that Qt
presentation backend.

## Recovery behavior

The compositor falls back to 1080p when the preferred mode cannot be entered.
Closing a Moonlight window does not destroy the remote browser capsule; its
server-side idle policy decides when an unused capsule is stopped. Input
services restart independently and refuse to route Synergy over an overlay
network. If the graphical shell fails, the local terminal binding and SSH
remain available for recovery.

Boot generations remain the rollback boundary for display-mode or Plymouth
experiments. A client-specific early-display override must not be generalized
into this profile.
