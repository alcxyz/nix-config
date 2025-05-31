# modules/home-manager/programs/hyprland/default.nix
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
  # Use our own dedicated option to gate THIS module's configuration
  # Renamed to better reflect its purpose: enabling *our* managed config
  cfg = config.programs.hyprland.managed;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
in
{
  # Declare our dedicated option (changed path for clarity)
  options.programs.hyprland.managed = {
    enable = mkEnableOption "Manage Hyprland configuration for this user via this module";
  };

  # This mkIf now ensures that everything *within* this block is only applied
  # when our custom programs.hyprland.managed.enable option is set to true
  # (e.g., in users/alc/home.nix).
  config = mkIf cfg.enable {

    # Now, inside the conditionally applied block, we enable the *built-in*
    # Home Manager wayland.windowManager.hyprland module and set its options.
    wayland.windowManager.hyprland = {
      enable = true; # Enable the built-in HM module itself

      # Configure the built-in module options found via home-manager search:
      xwayland.enable = true;
      systemd.enable = true; # Consider enabling this for user service integration with UWSM

      # --- Configuration directives for hyprland.conf ---
      # These go under the 'settings' option of the built-in module.
      # 'settings' takes an attribute set representing the configuration sections.
      settings = {
        general = {
          # Note: Hyprland uses 0xAARRGGBB or 0xRRGGBB format.
          # nix-colors provides RRGGBB hexadecimal strings.
          # We prefix with 0xff for full opacity (AA=ff).
          #"col.active_border" = "0xff${colors.base0C} 0xff${colors.base0D}"; # Gradient example
          #"col.inactive_border" = "0xff${colors.base00}";

          # Add other general settings here using the structured format
          # like:
          # gpus = "auto";
          # border_size = 2;
        };

        # Add other sections from your hyprland.conf here, translated
        # into the Nix attribute set structure, directly under 'settings'.
        # Example sections:
        # decoration = {
        #   rounding = 10;
        #   blur = { enabled = true; size = 3; passes = 1; };
        #   # ... other decoration settings
        # };
        #
        # animation = {
        #   enabled = true;
        #   # animations go here...
        # };
        #
        # binds = [
        #   "$mainMod, Q, killactive,"
        #   "$mainMod, M, exit,"
        #   # ... other keybinds as strings
        # ];
        #
        # windowRules = [
        #   "float,^(kitty)$"
        #   # ... other rules as strings
        # ];
      };

      # Use extraConfig for raw lines not covered by structured options
      # extraConfig = ''
      #   # Example raw lines:
      #   # exec-once = swayidle before-sleep 'swaylock -f' # For suspend/lock
      # '';

      # Other options from home-manager search can be set here,
      # directly under wayland.windowManager.hyprland:
      # plugins = [ pkgs.hyprland-plugins.hyprbars ];
      # package = pkgs.hyprland.override { ... };
      # portalPackage = pkgs.xdg-desktop-portal-hyprland.override { hyprland = pkgs.hyprland; };

    }; # End of wayland.windowManager.hyprland block

    home.pointerCursor = {
      gtk.enable = true;
      enable = true;
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
      size = 24;
      # visible = true;
    };

    # GTK theme settings
    # nix-colors will automatically configure
    # gtk.theme.name and gtk.theme.package based on config.colorscheme.name.
    gtk = {
      enable = true;
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
      # You can add other GTK settings here if needed, e.g.:
      # font.name = "Noto Sans 11";
    };

    # This session variable is correctly placed here.
    home.sessionVariables.NIXOS_OZONE_WL = "1";

    home.file.".config/hypr/scripts/fkey_handler.sh" = {
      source = ./scripts/fkey_handler.sh;
      executable = true;
    };

    xdg.configFile = {
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
