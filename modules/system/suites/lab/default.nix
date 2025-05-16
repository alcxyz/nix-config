{ options, config, lib, ... }:
with lib;
let
  cfg = config.suites.lab;
in
{
  options.suites.lab = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the lab suite configurations.";
    };
  };

  imports = mkIf cfg.enable [
    ./config.nix
    ./packages.nix
  ];
}
