{
  options,
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.programs.gnupg; # Updated option path
in
{
  options.programs.gnupg = with types; { # Updated option path
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable gnupg Home Manager configuration (agent and config file)."; # Updated description
    };
  };

  config = mkIf cfg.enable {
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