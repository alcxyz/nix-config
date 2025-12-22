# nix-config/modules/home-manager/suites/gaming/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.suites.gaming;
  gameAppsRegex = "steam|steam_app_.*|retrodeck|retroarch|gamescope";
in {
  imports = [ ./audio.nix ];
  options.suites.gaming.enable = lib.mkEnableOption "Gaming HM Suite";

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      gamescope
      mangohud
      helvum
    ];

  };
}
