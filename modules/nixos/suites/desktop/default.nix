{ options, config, lib, pkgs, inputs, username, ... }:
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

  config = mkIf cfg.enable { 
    environment.systemPackages = with pkgs; [
      #inputs.zen-browser.packages.x86_64-linux.default

      vivaldi
      brave
      thunderbird

      rustdesk
      spotify
      vlc
      obsidian
      obs-studio
      gimp3-with-plugins
      libreoffice
      calibre
      cameractrls
      cameractrls-gtk4
      gparted
      discord
      winetricks
      wineWowPackages.waylandFull

      nautilus

      pulseaudio

      git
      git-remote-gcrypt
      gh
      lazygit
      commitizen
    ];
  };
}
