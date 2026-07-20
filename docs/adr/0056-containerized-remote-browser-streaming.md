# ADR-0056: Containerized remote browser streaming

**Status:** Accepted, staged

**Applies to:** `hosts/xev`, `hosts/xps`, Wolf, Moonlight, browser sessions

## Context

The XPS couch session needs both a general browser and a private browser profile
for video-heavy use. Local browser playback is sensitive to the active display
topology and software-mirroring load. The existing SteamHeadless stream is
optimized for games and should not become the lifecycle, profile, or package
boundary for browser sessions.

A browser-streaming host must provide hardware video encoding, client-selected
virtual display modes, audio, keyboard, pointer, phone, and controller input,
and persistent but isolated browser homes. Private profile credentials, pairing
certificates, and access PINs must remain outside this public repository.

## Decision

Run [Wolf](https://games-on-whales.github.io/wolf/stable/) as a pinned
container on a GPU-capable NixOS host, with `xev` as the initial deployment.
Wolf provides Moonlight-compatible named applications and creates an isolated
virtual desktop for each application without requiring a physical monitor or a
dummy display plug.

The NixOS module:

- enables NVIDIA container CDI and starts Wolf only after its CDI inventory is
  available;
- mounts the Docker socket, DRM and virtual-input devices required by Wolf;
- stores certificates, pairings, profiles, and application homes in a
  configurable persistent state directory;
- exposes only Wolf's documented Moonlight protocol ports; and
- pins the Wolf image by platform digest instead of following a mutable tag.

Treat the state directory as private runtime data. Do not commit its generated
configuration, certificates, paired-client records, profile PINs, or browser
homes. A PIN-protected Wolf profile will contain the private Brave application;
the general profile will contain Helium. Their homes remain separate and
persistent across on-demand container replacement.

Roll out in two gates. First validate Wolf's upstream Firefox application at
the intended 1440p60 client mode, including NVENC, audio, keyboard, pointer,
phone input, and controller exit behavior. Only after the transport passes,
build pinned application images for Helium and Brave and add the controller
and keyboard launch actions on XPS. Keep local XPS browsers as a fallback.

The SteamHeadless deployment and its existing XPS launch action remain
unchanged. A browser-streaming failure must not start, stop, or modify the game
streaming host.

## Consequences

Browser rendering and video decode move off XPS while Moonlight retains the
controller-first couch experience. Wolf can serve multiple isolated
application profiles and adapt its virtual desktop to the Moonlight client's
requested resolution.

Wolf requires broad local access to Docker and input devices. Do not expose its
Unix control socket through a network proxy, and restrict host access to the
normal trusted-network policy. Pairing is explicit and its generated authority
material remains runtime state.

Changing the streaming host from the open-source display driver to the
proprietary NVIDIA stack requires a boot into the prepared generation. Perform
that host reboot through the existing maintenance workflow; do not live-switch
the GPU driver on a running cluster node.

## Alternatives considered

### Add browsers to the SteamHeadless container

Rejected because it couples browsing availability and profile persistence to
the game library, Sunshine, and container lifecycle on the Steam host.

### Run a second hand-built Sunshine/Xorg desktop

Rejected because it recreates virtual-display, input-relay, audio, and
application-isolation machinery that Wolf already provides.

### Keep all browser rendering local to XPS

Retained only as a fallback. It does not address the measured playback
sensitivity across mirror and multi-display layouts.

### Use VNC or RDP

Rejected for the primary couch path because they do not provide the same
low-latency video, audio, and controller integration already used by Moonlight.

## Tracking

- Implemented first as a reusable `services.wolf-streaming` NixOS module.
- Browser application images and XPS launch integration remain gated on the
  Firefox transport acceptance test.
