# ADR-0094: One Chromium browser (Brave Origin), Zen provisional

**Status:** Accepted (Zen provisional, see #662)
**Date:** 2026-10-13
**Applies to:** `modules/shared/pkgsets.nix`, `users/alc/linux/xyz.nix`,
`users/alc/linux/xyz/hyprland-contract.nix`, `hosts/xps/configuration.nix`,
`hosts/mac/configuration.nix`, the Wolf browser image products
(`publish-wolf-images.yml`), `hosts/xev/configuration.nix`

## Context

xyz, xps, the Mac and the Wolf remote-browser catalog ran three browsers: Zen,
Helium and Brave. Each had roles the others could also fill, so every role
change touched several profiles, keybinds, packages, images and update streams
(#628).

Resource use did not separate Helium and Brave: on the same muted YouTube
video, Brave used slightly less CPU and memory and Helium slightly less GPU.
Their capabilities did. Helium has no Widevine, so no Netflix or similar, and no
sync. Brave has both, and only Brave covered the DRM fallback and xps's synced
private profile. Brave Origin, in nixpkgs as `brave-origin` and free on Linux,
compiles out Leo, Rewards, Wallet, VPN and News, which removes most of the
trust and privacy advantage Helium had. On macOS Origin is a paid product.

## Decision

- **Brave Origin is the only Chromium browser on Linux.** It holds the xyz
  media, work sign-in and CDP profiles (Super+V and Super+Z, port 9223), the
  Bivrost sign-in browser, the xps protected couch browser and the xps local
  couch browser, and every Brave slot in the Wolf catalog: the public lobby
  browser and the private browser. Sync, Widevine, uBlock Origin and CDP were
  checked hands-on on xyz.
- **The Mac keeps regular Brave** (the `brave-browser` cask), because Origin is
  paid there.
- **Zen stays, provisionally, as the non-Chromium engine:** the main browser
  and default URL handler on xyz (Super+B), the Bane NOR sign-in browser on the
  Mac, and the Zen slot in the Wolf catalog with its `wolf-zen` image product.
  Its memory use has been high, partly from a Firefox WebGL bug fixed in
  Firefox 160. #662 measures it against Brave Origin once Zen ships Firefox
  160, and this ADR is amended with the keep or drop decision.
- **Helium and regular Brave on Linux are retired**, including their Wolf image
  products and the nix-packages Helium package. Rollback material is removed
  after a grace period (#663).

## Alternatives Considered

- **Helium as the Chromium browser:** a cleaner trust model (no company
  business features, no telemetry) and the lightest xps couch browser, but no
  Widevine and no sync, so Brave would have had to stay beside it. Revisit if
  Helium ships sync and DRM stops mattering.
- **Regular Brave with policies** that disable Leo, Rewards, Wallet, VPN and
  News: equivalent on capabilities, but the features stay in the binary and
  depend on policy keys staying honoured. Kept only on the Mac.
- **Brave only, no Zen:** fewer browsers still, but it gives up a non-Chromium
  engine and Zen's tab workflow. Deferred to the measurement in #662.

## Consequences

- One Chromium browser on Linux: one package, one Wolf image product, one
  update stream through nixpkgs lock bumps instead of a daily AppImage updater.
- Profiles carry across without re-encryption. On xyz, Brave Origin uses the
  same "Brave Safe Storage" keyring entry as regular Brave, so copied profiles
  keep their keyring-encrypted cookies and passwords. The xps couch browsers
  pass `--password-store=basic`, which needs no keyring, so Origin opens the
  existing encrypted profile mount in place.
- Brave Software's past incidents (affiliate codes in URLs, a Tor-window DNS
  leak, VPN services on Windows) remain the trust cost of this choice, reduced
  but not removed by Origin.
- The Mac runs a different Brave flavour from Linux, so settings and
  extensions that depend on the removed features can differ between them.
- Until #662 lands, Zen's memory use is accepted as the cost of keeping a
  second engine.
- ADR-0053 named Helium as the public and local couch browser and is amended
  to point here. ADR-0057 is superseded and keeps its Helium wording as history.
