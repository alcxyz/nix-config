# ADR-0052: Controller-first XPS couch session

**Status:** Accepted
**Date:** 2026-07-16
**Applies to:** `hosts/xps`, `modules/nixos/services/moonlight-client`, SteamHeadless integration

## Context

`xps` can serve as both a TV browser and a Moonlight client for a separate
SteamHeadless host. Starting Moonlight unconditionally during login couples the
local session to the availability of the remote stream host. When that host is
offline, a relaunch loop can leave the TV on an empty workspace and makes the
browser a secondary recovery path rather than a normal couch application.

The couch session must also remain usable without a keyboard. KDE Connect can
provide phone keyboard and pointer input through XTest, but those events only
reach XWayland clients. A physical controller therefore needs stable local
shortcuts for entering and leaving the stream, while the browser and Moonlight
need a compatible local input path.

## Decision

Boot the XPS couch session into a fullscreen XWayland browser. Do not start or
continually relaunch Moonlight during login.

Run a non-grabbing controller listener that survives controller reconnects and
recognises deliberately held shortcuts:

- hold `Home+A` to request the remote SteamHeadless service, wait for Sunshine,
  and start Steam Big Picture through Moonlight;
- hold `L3+R3` to stop the local Moonlight session and return to the browser.

The shortcuts require a hold interval to avoid accidental activation and do not
take exclusive ownership of the controller, so Moonlight can continue to use it
during a stream. The exit shortcut deliberately avoids the controller's Home
button because Moonlight forwards it to Steam as the Guide button.

Manage an active stream as an on-demand user service. Remote startup is
idempotent: skip it when Sunshine is already reachable, otherwise execute the
configured startup command and wait for the stream port before opening
Moonlight. A failed or unavailable remote host leaves the browser visible.

Run Moonlight through XWayland in this couch session so KDE Connect input can
reach the focused Moonlight window and be forwarded by the normal streaming
input path. Keep the normal desktop session as a separately persisted boot
mode.

Keep a compact keyboard escape hatch aligned with the normal workstation
bindings: open a terminal, create a fresh browser window, manage fullscreen and
floating windows, navigate or move between the stream and browser workspaces,
and control audio directly through PipeWire. DMS-specific shortcuts remain out
of couch mode because DMS is not part of that session.

Allow both native target-to-source mirrors and supervised fullscreen software
mirrors. Native mirroring is appropriate when every display shares a useful
mode. A software mirror keeps the streaming TV at its preferred mode while a
secondary display uses its own native mode and scale; relaunch the mirror after
either output disconnects and returns. Pin stream and browser workspaces to the
TV and reserve a separate secondary-output workspace for the mirror client.
Prefer a stable 60 Hz secondary mode over its native resolution when the
available dock path cannot sustain that native mode reliably.

KDE Connect's X11 backend can inject buttons, scrolling, and keys into focused
XWayland clients, but its pointer warp does not move Hyprland's compositor
cursor. While KDE Connect is enabled, mirror changed XWayland root-pointer
coordinates into Hyprland; let Hyprland hide the couch cursor after a short
idle period and reveal it again when pointer input resumes.

Use Chromium's basic password store for the isolated couch browser profiles.
Passwordless graphical auto-login cannot unlock the normal login keyring, and
an unlock dialog is unacceptable in a controller-first session. The normal
desktop browser and keyring configuration are unchanged.

The public module exposes generic startup, readiness, controller, and Qt
platform options. Authentication material and private operational details must
remain outside this repository.

## Alternatives Considered

### Start Moonlight unconditionally and relaunch forever

This works while the stream host is healthy but makes remote availability a
prerequisite for the local couch experience and can produce repeated failed
windows or empty workspaces.

### Restore DMS as the couch launcher

DMS adds desktop shell behaviour but does not solve remote-host lifecycle,
controller shortcuts, or XTest injection into native Wayland clients. It also
overlays streaming content unless separately hidden.

### Give the controller exclusively to a remapping daemon

Exclusive input ownership would simplify shortcut suppression but would require
creating and maintaining a second virtual controller for Moonlight. Observing
held combinations without grabbing the device is sufficient here.

### Stop SteamHeadless whenever Moonlight closes

Automatic remote shutdown would make brief disconnects and browser switches
expensive. Remote shutdown can be added later as a separate deliberate action.

## Consequences

XPS remains useful for browsing when the remote host or container is offline.
Starting a game stream takes one controller shortcut and includes remote service
startup when necessary.

The controller listener and stream service add local moving parts, but both are
declarative and independently observable. Controller reconnects do not require
restarting the graphical session.

Moonlight uses XWayland in couch mode to support phone input. Hardware decoding
remains enabled, but the XWayland presentation path should be retained only
while it meets latency and rendering expectations.

The couch browser profile must not be treated as a secure store for sensitive
saved credentials. Its basic password store is a deliberate kiosk trade-off;
credential-heavy browsing should use the normal desktop session.

SteamHeadless must expose a working virtual keyboard to its X server. That
integration has two boundaries: a system-wide host remapper must ignore the
synthetic `Keyboard passthrough` device, while the SteamHeadless container owns
the stream-specific delivery path. The container's headless Xorg has no active
virtual terminal, so its GitOps configuration relays only Sunshine's named
virtual keyboard and pointer devices through XTest. Physical host input is not
attached to the container's X server.

## Tracking

- Issue #140 tracks the initial controller-first rollout and live validation.
- Issue #141 tracks optional controller-native browser navigation and a
  deliberate remote shutdown action.
