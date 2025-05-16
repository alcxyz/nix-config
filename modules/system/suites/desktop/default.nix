{ options, config, lib, ... }:
with lib;
let
  cfg = config.suites.desktop;
in
{
  options.suites.desktop = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the desktop suite configurations.";
    };
  };

  imports = mkIf cfg.enable [
    ./config.nix
    ./packages.nix
  ];
}
