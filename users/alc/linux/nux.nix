# users/alc/linux/nux.nix
{ inputs, ... }:

let
  pkgsets = import ../../../modules/pkgsets.nix { inherit pkgs inputs; };
in

{
  # Import the common Linux configuration.
  imports = [ ./common.nix ];

  home.packages = pkgsets.home.server;
  # That's it!
  # If you ever need to add a package or setting *only* for nux,
  # you would add it here. For example:
  #
  # home.packages = [ pkgs.tmux ];
}
