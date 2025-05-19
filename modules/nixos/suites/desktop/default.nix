{ options, config, lib, pkgs, inputs, username, ... }: # Added username
with lib;
let
  cfg = config.suites.desktop; # This refers to options.suites.desktop
  # For options defined within *this* module (like desktop.enable, desktop.autoLogin below)
  # we refer to them via config.desktop inside the config block.
  # For options from *other* modules (like config.users.users), we use them directly.

in
{
  # Option for enabling the entire suite
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
