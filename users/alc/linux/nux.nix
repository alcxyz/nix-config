# users/alc/linux/nux.nix
{ ... }:

{
  # Import the common Linux configuration.
  imports = [ ./common.nix ];

  # That's it!
  # If you ever need to add a package or setting *only* for nux,
  # you would add it here. For example:
  #
  # home.packages = [ pkgs.tmux ];
}
