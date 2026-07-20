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
client a stable screen name, start it with the graphical session, and use the
Mac-oriented key map so physical Mac keycodes produce the expected Linux keys.
Enable transport encryption with trust on first use.

Keep client addressing configurable through the module rather than embedding
network topology or credentials in the implementation. Any private defaults,
license data, or operational details belong in the private configuration
boundary.

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
client.

## Tracking

- Issue #152 tracks the Mac rebuild and end-to-end input validation on both
  Waynergy clients.
