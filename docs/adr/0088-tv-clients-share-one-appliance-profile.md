# ADR-0088: TV clients share one appliance profile

**Status:** Accepted
**Date:** 2026-10-09
**Applies to:** `modules/nixos/profiles/nixbox-direct-client`, `modules/nixos/profiles/raspberry-pi-3-direct-client`, `hosts/rpi0`–`hosts/rpi3`, `inventory.nix`; amends ADR-0044

## Context

rpi0 (a Rock Pi 4 on the living-room TV) and rpi1 (a Raspberry Pi 3B+ on the
bedroom TV) do the same job: direct-DRM Moonlight clients for the Wolf browser
and SteamHeadless streams. They got there separately during the summer and
drifted apart ([#547](https://git.alc.xyz/alcxyz/nix-config/issues/547)):

- rpi0 had Bluetooth audio, NetBird and the monitoring agent; rpi1 had none.
- rpi0 started SteamHeadless by logging in to xyz as the operator and running
  `docker compose` in xyz's gitops checkout. The Pi 3 profile already used a
  forced, host-key-bound dispatcher on xyz.
- rpi0's TV audio output was labelled "Bedroom TV" although it is in the
  living room.
- The inventory called all four boards `embedded`, which said nothing about
  their job.

Both Pis also run Pi-hole and are the network's two DNS servers.

## Decision

`nixbox-direct-client` is the shared TV appliance layer. It owns everything a
TV client has regardless of board:

- the direct-DRM Moonlight session and the Wolf and SteamHeadless endpoints;
- SteamHeadless start and stop through the forced dispatcher on xyz, using the
  appliance's SSH host key, never an operator login;
- a Bluetooth audio receiver, named `Nixbox <room>`;
- the TV's HDMI audio output, labelled `<room> TV` from the `room` option;
- SD-card appliance defaults: no local builds, no desktop fonts, foreign-binary
  loader, smart-card daemon or container runtime, persistent but bounded
  journal, zram swap and three kept generations.

Hardware profiles add only what the board needs: `raspberry-pi-3-direct-client`
for the Pi 3 boards, and rpi0's host file for the Rock Pi 4. Stream bitrate,
frame rate and resolution stay with the hardware, since they follow its
decoder.

The inventory role for these hosts is `tv-client`, replacing `embedded`. It
keeps the small `embedded` package sets.

Every TV client should run NetBird and the monitoring agent. Their credentials
are per host and wired in nix-secrets; an appliance does not receive the
shared secret files for them. Pi-hole stays a separate, per-host concern.

xps is not a TV client. Its couch session (ADR-0053) and its future role are
tracked in [#548](https://git.alc.xyz/alcxyz/nix-config/issues/548).

## Alternatives and consequences

- **Keep per-host configuration:** each new feature had to be added twice and
  the hosts drifted, which is what #547 found.
- **A new profile beside `nixbox-direct-client`:** every direct-DRM client is a
  TV appliance, so a second layer would only add an import.
- **Give appliances the shared secret files:** simpler wiring, but it hands a
  device that sits in a living room every credential in those files.

The SteamHeadless dispatcher on xyz still runs `docker compose` from xyz's own
gitops checkout. The clients no longer depend on that path, but xyz does.

Because rpi0 and rpi1 are the only DNS servers, they must never be switched or
rebooted at the same time. Until the deploy tool can serialize them as their
own group, deploy them one at a time and confirm the first answers DNS before
touching the second.
