# Package pins (ADR-0110): top-level packages taken from another nixpkgs
# revision instead of the primary `nixpkgs` input, for every host and system.
#
# Each entry is keyed by the package's attribute name and has:
#   input       the flake input (declared in flake.nix) that provides it;
#   reason      why it is pinned and what ends the pin;
#   whileBroken optional, default false. When true, the pin applies only
#               while the primary package fails to evaluate (removed, marked
#               broken or throwing); once it evaluates again the primary one
#               is used and evaluation warns that the entry can go. Use it for
#               removals and evaluation errors. A package that evaluates but
#               fails to build or run needs whileBroken = false and removing
#               the entry by hand.
#
# To pin a package that a flake update broke: point `nixpkgs-previous` in
# flake.nix at a revision where it builds (usually the one the fleet ran
# before the update; check what other entries use it first), run
# `nix flake lock`, add an entry here and deploy. Remove the entry once
# nixpkgs works again.
{
  # nixpkgs removed brave and brave-origin on 2026-11-03 and re-added them
  # on 2026-11-07 (NixOS/nixpkgs#584534); nixos-unstable has not caught up
  # yet. The pin ends when the re-add reaches the channel. The Qt plugin fix
  # (#584621, 2026-11-08) comes with it: the first channel build that has
  # the re-add, at 177d054, has both.
  brave = {
    input = "nixpkgs-previous";
    reason = "removed from nixpkgs 2026-11-03, re-added 2026-11-07 but not yet in nixos-unstable";
    whileBroken = true;
  };
  brave-origin = {
    input = "nixpkgs-previous";
    reason = "removed from nixpkgs 2026-11-03, re-added 2026-11-07 but not yet in nixos-unstable";
    whileBroken = true;
  };

  # Host OpenBao stays at the reviewed 2.6.2 until adoption finishes and the
  # next release is reviewed.
  openbao = {
    input = "nixpkgs-openbao";
    reason = "held at the reviewed 2.6.2 until nixpkgs' version is accepted";
  };

  # Azure CLI stays until fabric supports invoke 3:
  # https://github.com/fabric/fabric/issues/2376
  azure-cli = {
    input = "nixpkgs-azure-cli";
    reason = "fabric does not support invoke 3 yet (fabric/fabric#2376)";
  };
  # The previous working package set, each with its own dependencies, until
  # the current nixpkgs build regressions clear.
  khal = {
    input = "nixpkgs-azure-cli";
    reason = "current nixpkgs build regression";
  };
  calibre = {
    input = "nixpkgs-azure-cli";
    reason = "current nixpkgs build regression";
  };
}
