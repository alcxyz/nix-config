{ options
, config
, lib
, pkgs
, inputs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.desktop.hyprland;
  #inherit (inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}) colors;
  colors = (inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}).palette;
in
{
  options.desktop.hyprland = with types; {
    enable = mkBoolOpt false "Enable or disable the hyprland window manager.";
  };

  config = mkIf cfg.enable {
    # Desktop additions
    desktop.addons = {
      waybar.enable = true;
      swww.enable = true;
      wofi.enable = true;
      swaync.enable = true;
      wlogout.enable = true;
      hypridle.enable = true;
      hyprlock = {
        enable = true;
        wallpaper = {
          useStandardDir = true;
          standardDir = "/home/alc/Pictures";
          filename = "lock.jpg";
          randomFromDir = false;
        };
      };
      hyprpanel = {
        enable = false;
        settings = {
          position = "top";
          height = 30;
          modules-left = ["dashboard" "workspaces" "window"];
          modules-center = ["clock" "media"];
          modules-right = ["volume" "network" "systray" "notifications"];
          # Add any other settings as needed
        };
      };
    };

    programs.hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    environment.sessionVariables.NIXOS_OZONE_WL = "1"; # Hint electron apps to use wayland

    environment.systemPackages = with pkgs; [
    ];

    # Hyprland configuration files
    home.configFile = {
      "hypr/launch".source = ./launch;
      "hypr/hyprland.conf".source = ./hyprland.conf;
      "hypr/colors.conf" = {
        text = ''
          general {
            col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
            col.inactive_border = 0xff${colors.base00}
          }
        '';
      };
    };
  };
}
