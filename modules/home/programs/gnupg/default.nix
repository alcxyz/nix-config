{
  config,
  lib,
  ...
}:
with lib;

{
  # This module configures the built-in Home Manager programs.gnupg module.
  # It does not define its own enable option, but depends on programs.gnupg.enable being set elsewhere.

  config = mkIf config.programs.gnupg.enable { # Use the built-in enable option
    # Home Manager configurations for GnuPG agent and config file
    programs.gnupg.agent = {
      enable = true;
      pinentryFlavor = "curses";
      enableSSHSupport = true;
    };

    home.file.".local/share/gnupg/gpg-agent.conf".source = ./gpg-agent.conf; # Path relative to this module

    environment.variables = {
      GNUPGHOME = "$XDG_DATA_HOME/gnupg";
    };
  };
}