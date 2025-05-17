{
  options,
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  cfg = config.desktop.hyprland;
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  options.desktop.hyprland = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Home Manager configuration for the Hyprland desktop environment suite.";
    };
    # Removed requiredSystemPackages option

    # Options to granularly control which addons are enabled within the suite
    waybar = { enable = mkEnableOption "Waybar configuration"; };
    swww = { enable = mkEnableOption "SWWW configuration"; };
    wofi = { enable = mkEnableOption "Wofi configuration"; };
    wlogout = { enable = mkEnableOption "wlogout configuration"; };
    hypridle = { enable = mkEnableOption "hypridle configuration"; };
    hyprlock = { enable = mkEnableOption "hyprlock configuration"; };
    hyprpanel = { enable = mkEnableOption "hyprpanel configuration"; };
    # Add options for other addons here
  };

  imports = mkIf cfg.enable [
    # Import individual Hyprland components here
    ./waybar/default.nix # Waybar
    ./swww/default.nix # SWWW
    ./wofi/default.nix # Wofi
    ./wlogout/default.nix # Wlogout
    ./hypridle/default.nix # Hypridle
    ./hyprlock/default.nix # Hyprlock
    ./hyprpanel/default.nix # Hyprpanel
    # ... and other addons
  ];

  config = mkIf cfg.enable {
    # Merged configuration for the core hyprland setup
    # Enable the built-in Home Manager Hyprland module and set its options
    programs.hyprland = {
      enable = true;
      withUWSM = true; # Keep as per original config
      xwayland.enable = true; # Keep as per original config
    };

    # Set Wayland environment variable for Electron apps
    environment.sessionVariables.NIXOS_OZONE_WL = "1"; # Keep as per original config

    # Configure Hyprland configuration files via Home Manager
    home.configFile = {
      "hypr/launch".source = ./launch; # Corrected path
      "hypr/hyprland.conf".source = ./hyprland.conf; # Corrected path
      "hypr/colors.conf" = { # Generate colors.conf using nix-colors palette
        text = ''
          general {
            col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
            col.inactive_border = 0xff${colors.base00}
            # Add other color-related settings here as needed from your hyprland.conf
          }

          # Example: setting a border color for a specific window rule if needed
          # windowrule =
          #   float,
          #   <window_class>
          #   bordercolor 0xff${colors.base0A}

        '';
      };
      # Include any other Hyprland config files managed by Home Manager here
    };

    # Explicitly enable the addons within the suite's config
    desktop.hyprland = {
      waybar.enable = true;
      swww.enable = true;
      wofi.enable = true;
      wlogout.enable = true;
      hypridle.enable = true;
      hyprlock.enable = true;
      hyprpanel.enable = false; # Keeping hyprpanel off as you indicated it's less important now
      # Set enable options for other addons here
    };

    # System packages are now managed by the new system suites.hyprland module.
    # desktop.addons configurations are handled by importing the submodules above.
  };
}