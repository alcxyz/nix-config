{ options, config, lib, pkgs, ... }:
with lib;
{
  options.desktop = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the desktop system configuration (services, features)."; # Updated description
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

    # Removed deluge and calibre-web service configurations
    # Removed related systemd service configurations
    # Removed related firewall rules

  };
}
