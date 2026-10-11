# Repository Instructions

This repository is public. Keep sensitive infrastructure details out of this
tree, including operational security models, hardware fingerprints, recovery
procedures, secret names, token scopes, private host bootstrap details, and
incident/debug transcripts that reveal exploitable behavior.

Use `nix-config` only for public host and user configuration, generic module
interfaces, and redacted ADRs. Put private runbooks, private module defaults,
secret wiring details, and sensitive implementation notes in the private
`nix-secrets` flake instead.

Do not move sensitive material to `nix-packages`; that repository is public too.

Agent skills (`SKILL.md` files) live in the private nix-secrets
`shared/skills/` (nix-secrets ADR-0016), not here; this repository keeps the
commands they call, their bundled assets and checks (ADR-0091).

## Hosts and deploys

Work on repositories and manage every host from `xyz` (or the Mac). The servers
`xev`, `nex` and `nux` and the Pis hold no repository clones; do not clone or
edit there.

Switch with `deploy`, which resolves the host and checks the package lock:
`deploy --hm` or `deploy --nixos` for the current machine, `deploy <host>` for
one remote host. Do not type `home-manager switch --flake .#alc-<host>` by
hand, since a wrong host name breaks that host's desktop. The user's `hmsw`
and `nxsw` shell aliases are interactive shortcuts that agent shells do not
have.

For changes that affect several hosts, recommend `deploy --all` from `xyz`:
the flake is meant to converge the whole fleet, so touching unaffected hosts is
not a risk. Do flag what breaks that, such as uncommitted or unpushed changes
in the tree being deployed, and units with `restartIfChanged = false` that need
a restart or reboot.

`rpi0` and `rpi1` serve DNS to the whole network; never have both down at once.
`deploy --all` switches them in parallel (nix-packages#504), so when a change
touches them, deploy `rpi0`, check DNS, then deploy `rpi1` before any
`deploy --all`; the later run finds them already converged.

`xps` is a battery-less laptop that stays docked in the living room. In
network and secret designs, group it with the stationary Pis rather than with
mobile clients. Its planned direction (media modes and an isolated agent mode,
no operator workstation) is tracked in #548; until then its current
configuration still includes a source workspace.

## Wolf browser input changes

Any change to the Wolf browser image's KDE Connect input path or process
lifecycle must pass `just input` before deployment. Pointer movement and primary
clicking are one acceptance contract: do not accept or deploy a change when only
one works.

Keep pointer mirroring, native button delivery, and daemon/bridge startup order
as separate responsibilities. Do not combine input-path changes with unrelated
video, image-hardening, or streaming changes in the same deployment. When
established input behavior regresses, restore the last working path before
attempting another design.
