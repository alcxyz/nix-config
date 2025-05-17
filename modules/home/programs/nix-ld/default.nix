{
  options,
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.programs.nix-ld; # Updated option path
in
{
  options.programs.nix-ld = with types; { # Updated option path
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable nix-ld Home Manager configuration."; # Updated description
    };
  };

  config = mkIf cfg.enable {
    programs.nix-ld.enable = true;
  };
}