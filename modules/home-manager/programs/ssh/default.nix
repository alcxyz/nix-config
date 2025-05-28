# modules/home-manager/programs/ssh/default.nix
{
  # Remove the 'options' argument as we are not declaring options here
  config, # The Home Manager configuration being built
  lib,    # Nixpkgs library functions
  # You can keep other arguments like pkgs if needed in the config block,
  # but they aren't strictly necessary for this simple file definition.
  ...
}:
with lib;

# This module provides configuration for the built-in Home Manager programs.ssh module.
# It *does not* declare its own options. It relies on the built-in module
# defining options like programs.ssh.enable.

{
  # The 'config' attribute provides configuration values.
  # This configuration is conditionally applied using mkIf, checking the
  # 'enable' option of the *built-in* programs.ssh module.
  # The built-in module declares programs.ssh.enable.
  config = mkIf config.programs.ssh.enable {

    # Configure the SSH client using options provided by the built-in
    # programs.ssh module, or by managing the config file directly.

    # Option 1 (Your current approach): Manage the config file directly using home.file
    # This is a valid way to place a literal config file for the user.
    home.file.".ssh/config".text = ''
      Host rpi*
        User root

      Host github
        Hostname github.com
        User git

      Host vps
        Hostname 46.202.150.96
        User root

      Host *
        identityfile ~/.ssh/key
    '';

    # Option 2 (Alternative, more declarative using the built-in module's structured options):
    # If you chose this path, REMOVE the home.file definition above.
    # This approach uses the structured options `matchBlocks` and `extraConfig`
    # provided by the built-in programs.ssh module.

    # programs.ssh.matchBlocks = {
    #   "rpi*" = { user = "root"; }; # Note the quotes for patterns with special chars like *
    #   "github" = { hostname = "github.com"; user = "git"; };
    #   "vps" = { hostname = "46.202.150.96"; user = "root"; };
    # };
    # # For the default '*' case, you could use extraConfig or another match block
    # # programs.ssh.extraConfig = ''IdentityFile ~/.ssh/key''; # Raw lines, might need careful placement
    # # Or, add a match block for '*':
    # programs.ssh.matchBlocks = lib.mkMerge [
    #   programs.ssh.matchBlocks # Include the blocks defined above
    #   {
    #     "*" = {
    #       identityFile = "~/.ssh/key";
    #       # Add other global SSH settings here
    #       # ServerAliveInterval = 60;
    #       # ServerAliveCountMax = 3;
    #     };
    #   }
    # ];

    # You might also want to specify the SSH package if not using the default
    # programs.ssh.package = pkgs.openssh; # Usually not needed if default is fine

  };
}
