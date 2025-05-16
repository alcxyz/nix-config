{ options, config, lib, pkgs, ... }:
with lib;
{
  options.desktop = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the desktop system configuration (services, features, firewall).";
    };
  };

  config = mkIf config.desktop.enable {
    apps.foot.enable = true;
    apps.wez.enable = true;

    desktop.hyprland.enable = true;
    programs.firefox.enable = true;

    programs.steam = {
      enable = true;
      };

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
    networking.fireall.allowedUDPPorts = [
    ];
  };
}
