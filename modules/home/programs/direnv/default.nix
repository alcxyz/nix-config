{
  options,
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.programs.direnv; # Updated option path
in
{
  options.programs.direnv = with types; { # Updated option path
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable direnv Home Manager configuration"; # Updated description
    };
  };

  config = mkIf cfg.enable {
    home.programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    environment.sessionVariables.DIRENV_LOG_FORMAT = ""; # Blank so direnv will shut up
  };
}