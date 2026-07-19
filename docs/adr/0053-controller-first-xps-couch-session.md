# ADR-0053: Controller-first XPS couch session

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
provide phone keyboard, click, and scroll input through XTest, but those events
only reach XWayland clients. A physical controller therefore needs stable local
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

Keep the known-good couch and desktop profiles intact and offer a third
`merged` profile for the combined experience. The merged profile reuses the
controller-first Hyprland session while running DMS against an isolated
runtime configuration: disable idle locking, monitor power-off, suspension,
login lock integration, and shell sounds; keep the bar and dock strictly
auto-hidden. Entering a stream hides both shell surfaces and enables DMS do-not-
disturb, while returning to the browser reveals their auto-hiding forms. This
switch happens without restarting Hyprland or discarding browser state. Run the
isolated DMS process as a restartable user service so a shell crash or display
transition cannot silently remove it for the rest of the session.

Keep a compact keyboard escape hatch aligned with the normal workstation
bindings: open a terminal, create a fresh browser window, manage fullscreen and
floating windows, navigate or move between the stream and browser workspaces,
and control audio directly through PipeWire. DMS-specific shortcuts remain out
of couch mode because DMS is not part of that session.

Expose the laptop's display-audio PCMs simultaneously through WirePlumber's
pro-audio profile and label them by display role. This lets DMS present the two
TV paths and auxiliary display as independent sinks without changing the whole
card profile on every selection. Connected Bluetooth speakers join the same
PipeWire sink list. Cycle available sinks with held controller Select plus the
west face button or `Super+Shift+A`; retain DMS's normal output picker for phone
and pointer use. When a Bluetooth device that identifies as a speaker is
manually connected, activate its A2DP playback path but leave output selection
manual. Pairing and trust data remain host state rather than public
configuration.

Expose a latency-compensated `Both TVs` virtual PipeWire sink that fans a stereo
stream out to the two TV-class display sinks. This pairs naturally with TV
mirroring, but remains an explicit audio choice so toggling a display mode never
changes volume or routing unexpectedly.

Persist the explicit mirroring choice alongside the selected display layout.
Default it off for a fresh host, but preserve an operator toggle across reboots
so a requested dual-TV mirrored session actually returns in that state.

Publish the controller and keyboard reference as a generated DMS cheatsheet.
Toggle the native DMS modal from either input type so it follows the focused
display without adding a separate desktop dialog or placement workaround.

Expose display management through a DMS bar plugin in the merged profile. Keep
the host commands authoritative for applying layout, mirror, and audio policy;
the plugin is a presentation layer that reads effective outputs directly from
Hyprland. Show persisted policy separately from the active display set so a
hotplug fallback or armed mirror request is not mistaken for the visible state.
Use couch-sized full-row actions and direct layout choices instead of requiring
users to remember or repeatedly cycle keyboard and controller shortcuts. Share
the normal plugin directory with the isolated merged DMS configuration and put
the required host commands explicitly in that service's execution path.

Use DMS's built-in Polkit agent for privileged graphical authentication and
enable NixOS's setuid `pkexec` wrapper on XPS. Administrative couch actions can
therefore request authorization through a DMS-owned modal instead of binding a
sudo password prompt to an SSH terminal. This does not replace application
secret prompts such as the encrypted Brave profile password, which are not
Polkit authorization requests.

Keep attached secondary and tertiary displays independent in the all-output
layout. Assign persistent workspaces 1–3, 4–6, and 7–9 across the three external
outputs; in a solo layout, return all workspace sets to the selected output.
Park inactive-but-connected outputs outside the usable desktop before powering
them down so the cursor cannot escape onto a display whose adapter retains its
connection while the panel is in standby.

Persist the selected layout across reboots. Adaptive mode preserves the sole
active output and falls back to the physically largest connected output; also
provide an explicit dual-TV layout that activates the two largest TV-class
outputs while parking an attached auxiliary display. Also provide explicit
primary-TV-plus-auxiliary and secondary-TV-plus-auxiliary layouts. Classify the
second TV and auxiliary output by physical role instead of merely taking the
next ranked connector; this preserves workspaces 4–6 for the second TV and
7–9 for the auxiliary display, and prevents a persisted TV-mirror request from
targeting the auxiliary display when only one TV is selected. Keep all-output
and ranked solo-output modes as deterministic recovery controls. Cycle those
modes with held controller Select plus the north face button or
`Super+Shift+D` on a keyboard. Changing between multi-output layouts does not
override a manually selected audio sink.

Treat cable presence as a hard availability signal, but do not infer panel
power from it. A powered-off panel behind an adapter can continue reporting as
connected and DPMS-on without exposing CEC or DDC/CI state. Consequently, a
cabled display change requires deliberate layout selection; an unplugged
requested display falls back by role to the highest-priority available TV, then
to an auxiliary display. This avoids presenting unreliable power heuristics as
automatic detection.

An on-demand mirror toggle can use Hyprland's native mirror path when the two
selected displays have matching pixel dimensions, and otherwise uses a
supervised fullscreen `wl-mirror` client. Allow a host to force the supervised
path even for matching modes: XPS reports a valid native mirror relationship but
leaves the physical source panel blank, while the software path preserves both
TV signals correctly. The supervised path negotiates the compositor's DMA-BUF
capture backend, keeping the copied frames GPU-backed. Use a shared 1080p60 mode
while browser playback is mirrored: validation showed that decoding 1080p into
two 1440p compositor outputs dropped frames heavily, while matching the video
and output modes did not. A single 1440p compositor output reduced but did not
eliminate the regression, and 1440p video increased it further. Restore
1440p60 when mirroring is disabled for sharper desktop use, while retaining
1080p60 as the validated smooth-playback path. Prefer a stable 60 Hz auxiliary
mode over native resolution when the available dock path cannot sustain that
native mode reliably.

Treat display-pipeline allocation separately from logical Hyprland layout. If
all three external displays are connected during boot, release the internal
panel before the graphical session starts; with fewer external displays, keep
the internal panel available as a local maintenance fallback.

Do not persist dock connector names or display identities. Rank connected
outputs by physical area, keep unmatched outputs on the stable secondary mode,
and atomically regenerate transient monitor and workspace rules whenever the
dock renames a connector after a link flap. Write parked-output positions before
active-output positions so a live transition never temporarily overlaps two
extended outputs.

KDE Connect's X11 backend can inject buttons, scrolling, and keys into focused
XWayland clients, but its pointer warp does not move Hyprland's compositor
cursor. Do not mirror XWayland root-pointer coordinates into Hyprland: that
feedback loop also reacts to physical pointer movement over an XWayland window
and makes the compositor cursor disappear. Phone pointer movement remains a
separate Wayland-injection problem; preserve reliable physical pointer input
and the KDE Connect input types that work without the bridge.

Expose the credential-bearing couch browser only through a password-gated
launcher backed by an encrypted profile directory. Keep the unrestricted
browser executable and desktop entry out of the user profile. The browser uses
its basic password store inside that encrypted directory because passwordless
graphical auto-login cannot unlock the normal login keyring without an
unacceptable unlock dialog. The normal desktop browser and keyring
configuration are unchanged. Capture the focused workspace when the launcher is
invoked, then place and centre its password prompt and browser windows there.
Launch couch browsers as ordinary tiled windows rather than requesting browser
or compositor fullscreen, because Chromium fullscreen interferes with couch
pointer and click handling. Apply an explicit browser device scale for readable
chrome and page content without reducing the stream or workspace resolution.

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

The protected couch browser profile is encrypted while closed, but becomes
available to the logged-in couch session while the launcher is running. It is
an access boundary for casual use, not a substitute for separate user accounts
or full-session locking.

SteamHeadless must expose a working virtual keyboard to its X server. That
integration has two boundaries: a system-wide host remapper must ignore the
synthetic `Keyboard passthrough` device, while the SteamHeadless container owns
the stream-specific delivery path. The container's headless Xorg has no active
virtual terminal, so its GitOps configuration relays only Sunshine's named
virtual keyboard and pointer devices through XTest. Physical host input is not
attached to the container's X server.

## Tracking

- Issue #140 tracks the initial controller-first rollout and live validation.
- Issue #141 tracks optional controller-native browser navigation, a proper
  Wayland-compatible phone pointer path, and a deliberate remote shutdown
  action.
