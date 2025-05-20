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
      inputs.zen-browser.packages.x86_64-linux.default

      brave
      thunderbird
      chromium
      teams-for-linux
      rustdesk
      spotify
      vlc
      obsidian
      obs-studio
      gimp3-with-plugins
      calibre
      cameractrls
      cameractrls-gtk4
      gparted
      discord
      lutris
      winetricks
      wineWowPackages.waylandFull

      ghostty
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
