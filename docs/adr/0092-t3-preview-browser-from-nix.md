# ADR-0092: Provide T3's preview browser from the Nix package

**Status:** Accepted
**Date:** 2026-10-10
**Applies to:** `modules/home-manager/services/t3code/`, nix-packages `pkgs/t3code`

## Context

T3 Code renders HTML previews and server-side browser tabs with a Chrome for
Testing headless shell. T3 pins one build in its source and downloads it into
`<baseDir>/tools/chrome-headless-shell/<platform>/<version>/` on first use.
On NixOS that prebuilt binary cannot find its libraries (glib, NSS, X11 and
others), so every preview fails. A headless host is not the cause: the shell
renders without a display, but it still links the X11 libraries.

T3 offers no setting to use another browser. It treats a version directory
with an executable `chrome-headless-shell` as installed, and replaces only
other versions when it installs a new pin.

## Decision

nix-packages builds the pinned browser alongside T3: it reads the version and
archive hash from the T3 source being built, fetches the same archive and
patches it to load its libraries from the store. The T3 package exposes it at
`libexec/t3code/preview-browser/<platform>/<version>`.

Each T3 instance runs `t3code-link-preview-browser` before starting. It links
that version directory into the instance's base directory, replacing T3's own
unusable download. With unattended updates the link goes through the
ai-stack profile (ADR-0077), so it follows profile switches; the update's
restart relinks a new version and removes links the profile no longer
provides. A failing link step never blocks T3 from starting.

## Alternatives and consequences

- **Add the libraries to `programs.nix-ld.libraries`:** one line of host
  configuration, but it exposes a browser's libraries to every unpatched
  binary on the host.
- **Set `NIX_LD_LIBRARY_PATH` on the T3 service:** narrower, but every agent,
  shell and tool T3 starts would inherit it.
- **Run T3 in an FHS environment:** contains the libraries, but wraps the whole
  server for one feature.

The libraries now belong to the browser's closure alone. The link relies on
T3's install layout, which is not a supported interface. If T3 changes it, T3
downloads its own copy again and previews report missing libraries, as they
did before; nothing else breaks. If T3 changes how it declares the pin,
evaluating the T3 package fails, so the update is held back until the
extraction is updated (nix-packages ADR-0003). Reading the pin is import from
derivation, so evaluating the T3 package, and the xyz configuration that seeds
the ai-stack profile, fetches the T3 source and needs import from derivation
enabled.
