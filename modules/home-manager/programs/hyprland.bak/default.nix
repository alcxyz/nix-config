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
      enable = true;

      # Configure the built-in module options found via home-manager search:
      xwayland.enable = true;
      systemd.enable = true;

      # Use the same pinned Hyprland build
      package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;

      # Use the matching portal build (keeps ABI aligned)
      portalPackage =
        inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;

      # Enable plugins from the pinned hyprland-plugins flake
      plugins = [
        inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprexpo
        inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprscrolling
        # inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprfocus
      ];

      settings = {
        general = {
          "col.active_border" = "0xff${colors.base0C} 0xff${colors.base0D}";
          "col.inactive_border" = "0xff${colors.base00}";
          border_size = 2;
          gaps_in = 5;
          gaps_out = 10;
        };
        decoration = {
          rounding = 10;
          "col.shadow" = "0xff${colors.base00}";
        };
      };

    };

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

      "hypr/gaming.conf" = {
        text = ''
          # Gaming Suite Configuration
          $ws_gaming = ${config.suites.gaming.gamingWorkspace or "1"}

          # --- THIS BINDING IS NOW SIMPLE ---
          # It's only job is to launch the process. The window rules below will handle placement.
          bind = SUPER, G, exec, flatpak run com.valvesoftware.Steam -bigpicture

          # --- ROBUST WINDOW RULES ---
          # These rules will catch all relevant windows and dispatch them correctly.

          # Rule 1: Catch the initial Steam window (class 'steam') and move it.
          windowrulev2 = workspace $ws_gaming silent,class:^(steam)$

          # Rule 2: Catch the final Gamescope window and ensure it's on the correct workspace and fullscreen.
          # This is still important as it takes over from the initial window.
          windowrulev2 = workspace $ws_gaming silent,class:^(gamescope)$
          windowrulev2 = fullscreen,class:^(gamescope)$

          # --- Specific Rules for the HEADLESS STREAMING Session ---
          # These rules remain the same and are still correct.
          windowrulev2 = nofocus, title:^(GamescopeStream)$
          windowrulev2 = noinitialfocus, title:^(GamescopeStream)$

          # Start the audio monitor automatically on login.
          exec-once = workspace-audio-monitor monitor
        '';
      };

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
