{ options, config, lib, pkgs, ... }:
with lib;
{
  options.desktop = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the desktop system configuration (services, features)."; # Updated description
    };
    # Add the autoLogin option for the system level
    autoLogin = mkOption {
      type = types.bool;
      default = false;
      description = "Enable automatic login for the desktop user.";
    };
  };

  config = mkIf config.desktop.enable {
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

      # Add autoLogin configuration
      displayManager.autoLogin = mkIf config.desktop.autoLogin {
        enable = true;
        user = config.users.users.${config.username}.name; # Use config.users.users.${config.username}.name to get the primary user's name
      };
    };

    # Removed deluge and calibre-web service configurations
    # Removed related systemd service configurations
    # Removed related firewall rules

  };
}
