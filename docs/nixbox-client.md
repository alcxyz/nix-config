# Compact Nixbox client

`services.nixbox-client` is the reusable, small-host counterpart to the XPS
media-center workbench. It composes the existing Moonlight client rather than
forking its launch, input, audio, or recovery logic.

## Included experience

- a controller-first Hyprland session with remote Steam and browser streams;
- a compact, auto-hiding DMS shell with idle locking and suspension disabled;
- KDE Connect keyboard, pointer, click, and scrolling support through the
  XWayland/Hyprland bridge;
- LAN-only Waynergy input from a Synergy server, using an output-bound WLR
  pointer so movement follows the active couch display;
- compositor-owned login, logout, reboot, and shutdown transitions, with an
  optional Nixbox Plymouth boot theme for hosts where early boot graphics are
  worth the added boot-path complexity;
- selectable local display audio and a local sound-system output;
- a local terminal as a maintenance escape hatch; and
- a preferred output mode with a 1080p fallback.

The profile deliberately does not include local browsers, protected profiles,
developer tools, multiple-display workspace policy, or the XPS dock-specific
Plymouth replay service. Browser state and rendering live on the remote stream
host.

Compact appliances should also use a dedicated Home Manager profile rather
than inherit an operator or workstation profile. Keep only the shell tooling
needed for local recovery; DMS, Waynergy, and their runtime dependencies should
be owned by their respective modules.

## Configuration boundary

The public profile owns generic behavior and exposes options for the session
user, output mode and scale, Moonlight package, and optional presentation and
input features. Host-specific display quirks, private endpoints, credentials,
and pairing state remain outside this repository or in runtime state.

The client defaults Moonlight to XWayland because the current remote-input path
uses its focused keyboard, button, and scroll delivery while pointer motion is
kept compositor-native. KDE Connect pointer warps are forwarded through a
scoped runtime socket rather than mirrored from the X11 root cursor. Hardware
video decoding remains a property of the selected Moonlight package and is
independent of that Qt presentation backend.

## Direct-display streams

Small clients can opt into one-shot direct-display modes for Steam and remote
browsers. In these modes Moonlight uses EGLFS/DRM and owns the display instead
of being composited by Hyprland. This materially lowers the client rendering
overhead while preserving server-side concurrency: another client can remain
connected to the same stream host, and independent stream hosts remain
unaffected.

The stream coordinate space does not have to match the physical output. A
compact client may request a 2560×1440 stream while its kernel framebuffer
remains fixed at 1920×1080 at 60 Hz. Moonlight scales presentation locally;
absolute pointer input still covers the complete remote desktop because its
coordinates follow the requested stream resolution.

Direct-display mode deliberately suspends compositor-bound DMS, KDE Connect,
and Waynergy processes. Physical keyboard, mouse, and controller input continue
to reach Moonlight directly. Exiting the stream restores the previous session
mode and Hyprland starts the suspended user services again. Use the normal
Hyprland/XWayland stream path when phone or Synergy input is required.

## Recovery behavior

The compositor falls back to 1080p when the preferred mode cannot be entered.
Closing a Moonlight window does not destroy the remote browser capsule; its
server-side idle policy decides when an unused capsule is stopped. Input
services restart independently and refuse to route Synergy over an overlay
network. If the graphical shell fails, the local terminal binding and SSH
remain available for recovery.

Normal and protected browser launchers may target separate coordinator
hostnames and ports while sharing the same physical streaming server. Compact
clients keep a distinct Moonlight XDG profile for the protected selector, so a
restart or recovery of its coordinator does not interrupt the public browser
session.

Boot generations remain the rollback boundary for display-mode or Plymouth
experiments. Set `enableBootSplash = false` on compact hosts that should retain
the normal console boot while keeping the compositor-owned transitions. A
client-specific early-display override must not be generalized into this
profile.

A normal direct-display exit returns immediately. If Moonlight becomes
unresponsive, the session wrapper still restores the saved mode; greetd's
bounded service-stop fallback remains the final recovery boundary.
