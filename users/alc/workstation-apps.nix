# users/alc/workstation-apps.nix
# Maintained apps used only from the owner's workstations (xyz and mac).
{
  pkgs,
  inputs,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
in {
  home.packages = [
    inputs.grove.packages.${system}.default
    inputs.canopy.packages.${system}.default
    inputs.paw.packages.${system}.paw
  ];

  # PAW workspaces are reached as Git remotes through the ext:: transport
  # (paw workspace repository remote), which Git disables unless allowed.
  # Only hosts that install paw opt in.
  programs.git.settings.protocol.ext.allow = "user";
}
