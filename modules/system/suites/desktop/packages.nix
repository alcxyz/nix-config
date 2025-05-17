{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
with lib;

{
  config = mkIf config.suites.desktop.enable {
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
      #(calibre.override {
      #  unrarSupport = true;
      #})
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

      # Add Git and related tools
      git
      git-remote-gcrypt
      gh
      lazygit
      commitizen

      # Hyprland and its addons packages will be managed by a separate system suite.
    ];
  };
}