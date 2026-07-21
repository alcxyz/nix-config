# ADR-0054: Mac-hosted Synergy 1 with Waynergy clients

**Status:** Accepted
**Date:** 2026-07-19
**Applies to:** `users/alc/linux/{xps,xyz}.nix`, `modules/home-manager/services/waynergy`

## Context

The workstation keyboard and pointer should move between the Mac and the two
Wayland Linux workstations without requiring a second physical input set.
Synergy 1 is already licensed, but its macOS release is distributed as a binary
disk image and its upstream Linux client is not a native Wayland input client.

## Decision

Run the licensed Synergy 1 application on macOS as the server. Install the
`synergy-core` formula with Homebrew rather than placing the proprietary disk
image behind a fixed-output Home Manager package. Keep license material out of
the public flake.

Run Waynergy as a Home Manager user service on each Wayland client. Give each
client a stable screen name and start it from the persistent user default
target. Use the Mac-to-evdev raw map so physical Mac keycodes become the same
standard Linux
keycodes produced by attached keyboards and other input bridges. This keeps
downstream remote-desktop clients from receiving Mac-specific scancodes while
still making Command act as Super.
Enable transport encryption with trust on first use.

Use relative pointer motion on the Synergy server. A client compositor may
retain powered-off outputs outside the visible desktop so it can restore them
without losing layout state; mapping absolute motion across that full bounding
box makes the visible pointer excessively sensitive. On couch clients,
Waynergy also advertises the focused powered-on monitor at startup rather than
the full compositor output bounding box.

Keep the couch compositor's global controls available when a fullscreen remote
desktop client requests shortcut inhibition. This lets Command from the Mac
act as Super for workspace and application controls without preventing regular
keys from reaching the remote session.

Launch the client through a session-aware wrapper that reads the user service
manager's current Wayland environment and waits for the advertised compositor
socket. Do not depend on Home Manager's `graphical-session.target`: greetd/UWSM
couch sessions may never activate it. The default-target service can start
before UWSM imports the environment because the wrapper waits for the socket;
keep early clean exits retryable so boot timing cannot leave input sharing
inactive for the rest of the session.

Keep client addressing configurable through the module rather than embedding
network topology or credentials in the implementation. Any private defaults,
license data, or operational details belong in the private configuration
boundary.

Synergy is a local input transport, not a remote-access service. Resolve its
server to a private LAN address and fail closed unless the selected route uses
a non-overlay interface. In particular, never allow an unavailable LAN path to
fall back through a mesh VPN: the additional latency makes pointer movement
unusable and remote input sharing is outside this setup's purpose.

## Alternatives Considered

### Run Synergy's Linux client under XWayland

This does not provide the compositor-native input path required by the Wayland
sessions and introduces additional focus and key translation failure modes.

### Use the Mac as a client

The desired physical keyboard and pointer are attached to the Mac, so making it
the server matches the normal direction of control.

### Upgrade solely to use Synergy 3

The existing Synergy 1 license already satisfies the server protocol needed by
Waynergy. A paid upgrade is not required for this topology.

## Consequences

The Mac application is managed outside Home Manager through Homebrew, avoiding
a user-provided installer blocking unrelated Home Manager generations. Linux
clients reconnect automatically when their graphical sessions or the server
return. Initial server trust still requires deliberate verification on each
client. Relative pointer mode is required on the server for clients whose
compositors preserve inactive outputs outside the visible layout.
If the Mac is unavailable on the physical LAN, Waynergy remains disconnected
instead of selecting a VPN route.

## Tracking

- Issue #152 tracks the Mac rebuild and end-to-end input validation on both
  Waynergy clients.
- LAN-only route enforcement on XPS: implemented and verified.
- Default-target startup across greetd/UWSM sessions: implemented after live
  validation showed `graphical-session.target` remained inactive on both XPS
  and XYZ.
