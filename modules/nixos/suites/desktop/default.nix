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
      grim
      slurp
      swappy
      imagemagick

      (writeShellScriptBin "screenshot" ''
        grim -g "$(slurp)" - | convert - -shave 1x1 PNG:- | wl-copy
      '')
      (writeShellScriptBin "screenshot-edit" ''
        wl-paste | swappy -f -
      '')

      pulseaudio
      git
      git-remote-gcrypt
      gh
      lazygit
      commitizen
    ];
  };
}
