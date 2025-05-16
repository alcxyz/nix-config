{ options
, config
, lib
, pkgs
, inputs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.suites.desktop;
in
{
  options.suites.desktop = with types; {
    enable = mkBoolOpt false "Enable the desktop suite";
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
      #(calibre.override {
      #  unrarSupport = true;
      #})
      calibre
      calibre-web

      cameractrls
      cameractrls-gtk4
      gparted

      discord
      lutris
      winetricks
      wineWowPackages.waylandFull

      ghostty
      deluge

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
    ];

    apps.foot.enable = true;
    apps.wez.enable = true;

    desktop.hyprland.enable = true;
    programs.firefox.enable = true;

    programs.steam = {
      enable = true;
      };

    #apps.tools.gnupg.enable = true;

    services.flatpak.enable = true;

    services.xserver = {
      enable = true;
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
    };

    services.deluge = {
      enable = true;
      user = "${config.user.name}";
      group = "users";
      dataDir = "/home/alc";
      web.enable = true;
    };

    services.calibre-web = {
      enable = true;
      user = "${config.user.name}";
      dataDir = "/hyperdisk/vault/calibre/calibre_web/config";
      options.calibreLibrary = "/hyperdisk/vault/calibre/calibre/config/libraries/Main";
      listen = {
        ip = "0.0.0.0";
        port = 8083;
      };
      openFirewall = true;
    };

    systemd.services.deluged = {
      after = [ "zfs-mount.service" ];
    };

    systemd.services.calibre-web = {
      after = [ "zfs-mount.service" ];
    };

    networking.firewall.allowedTCPPorts = [
      8112
      51413
    ];
    networking.firewall.allowedUDPPorts = [
    ];

    #environment.persist.directories = [
    #  "/etc/gdm"
    #];
  };
}
