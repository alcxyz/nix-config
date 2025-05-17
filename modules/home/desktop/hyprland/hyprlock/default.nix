{
  options
, config
, lib
, pkgs
, inputs
, ...
}:
with lib;

let
  # Depend on the parent desktop.hyprland.enable option (handled by mkIf in the config block)
  # parentCfg = config.desktop.hyprland;

  # Define options specific to this hyprlock module
  cfg = config.desktop.hyprland.hyprlock; # Use the correct nested option path

  # Create the lock script that can optionally turn off displays
  lockScript = pkgs.writeShellScriptBin "lock-screen" ''
    # Ensure hyprlock and hyprctl are in the PATH or use full paths
    HYPRLOCK="${cfg.package}/bin/hyprlock"
    HYPRCTL="${pkgs.hyprland}/bin/hyprctl"

    $HYPRLOCK ${optionalString (!cfg.turnOffDisplaysOnLock) "& exit 0"}

    # If we're turning off displays, wait for specified delay then do it
    ${pkgs.coreutils}/bin/sleep ${toString cfg.displayOffDelay}
    $HYPRCTL dispatch dpms off
  '';

in {
  options.desktop.hyprland.hyprlock = with types; { # Define options nested under desktop.hyprland
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Home Manager configuration for the hyprlock screen locker.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.hyprlock;
      description = "The hyprlock package to use";
    };

    turnOffDisplaysOnLock = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to turn off displays after manual locking";
    };

    displayOffDelay = mkOption {
      type = types.int;
      default = 10;
      description = "Seconds to wait before turning off displays after manual locking";
    };

    # Note: lockTimeout and dpmsTimeout were options in the original hypridle module
    # that configured hypridle to *call* the lock command.
    # Here, we are configuring the lock command *itself*. These options might belong back in hypridle.

    lockCommand = mkOption {
      type = types.str;
      # Default to the custom lock script provided by this module
      default = "${lockScript}/bin/lock-screen";
      description = "Command to run to lock the screen";
    };

    hyprctlCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprland}/bin/hyprctl"; # Default to hyprctl binary path
      description = "Path to hyprctl command";
    };

    wallpaper = { # Wallpaper configuration options
      # Enhanced wallpaper options
      path = mkOption {
        type = types.str;
        default = "screenshot";
        description = ''
          Path to wallpaper image. Special values:
          - "screenshot": Use a screenshot of the current desktop
          - "/path/to/image.jpg": Use a specific image file
          Note: This is ignored if useStandardDir is true.
        '';
      };

      # New options for standard wallpaper directory
      useStandardDir = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use the standard wallpapers directory";
      };

      standardDir = mkOption {
        type = types.str;
        # Use the wallpapers directory from the Home Manager desktop module
        # Assumes the desktop module defines desktop.wallpapersDir or similar.
        # For now, hardcoding a likely path, but this could be made an option.
        # default = "/home/${config.home.username}/.config/wallpapers";
        # Let's refer to the wallpapers directory in the parent Hyprland module
        # Assumes the parent Hyprland module defines an option for wallpapers dir.
        # For now, hardcode the path relative to the user's home dir.
        default = "${config.home.homeDirectory}/.config/wallpapers";
        description = "Path to the standard wallpapers directory";
      };

      filename = mkOption {
        type = types.str;
        default = "default.jpg";
        description = "Wallpaper filename in the standard directory";
      };

      randomFromDir = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use a random wallpaper from the standard directory";
      };

      color = mkOption {
        type = types.str;
        default = "rgba(25, 20, 20, 1.0)";
        description = "Background color to use behind the wallpaper";
      };

      blur = { # Blur options
        size = mkOption {
          type = types.int;
          default = 7;
          description = "Blur size for the background";
        };

        passes = mkOption {
          type = types.int;
          default = 3;
          description = "Number of blur passes to apply";
        };
      };
    };
  };

  # Apply configuration if this module is enabled (depends on parent Hyprland suite enablement)
  config = mkIf cfg.enable {
    # Install the custom lock script as a user package
    home.packages = [ lockScript ];

    # Create configuration for hyprlock
    home.configFile."hypr/hyprlock.conf" = {
      text = 
        let
          # Calculate the wallpaper path here based on options
          wallpaperPath = 
            if cfg.wallpaper.useStandardDir then # <--- Check useStandardDir FIRST
              if cfg.wallpaper.randomFromDir then
                # Use find, shuf, and coreutils with full paths
                "$(${pkgs.findutils}/bin/find ${cfg.wallpaper.standardDir} -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) | ${pkgs.coreutils}/bin/shuf -n 1)"
              else
                "${cfg.wallpaper.standardDir}/${cfg.wallpaper.filename}"
            else if cfg.wallpaper.path == "screenshot" then "screenshot" # <--- Then check for explicit "screenshot"
            else
              cfg.wallpaper.path; # <--- Otherwise, use the explicit path set by the user
        in
        ''
          background {
              monitor =
              path = ${wallpaperPath}
              color = ${cfg.wallpaper.color}
              blur_passes = ${toString cfg.wallpaper.blur.passes}
              blur_size = ${toString cfg.wallpaper.blur.size}
              noise = 0.0117
              contrast = 0.8916
              brightness = 0.8172
              vibrancy = 0.1696
              vibrancy_darkness = 0.0
          }

          input-field {
              monitor =
              size = 200, 50
              outline_thickness = 3
              dots_size = 0.2
              dots_spacing = 0.64
              outer_color = rgb(151515)
              inner_color = rgb(200, 200, 200)
              font_color = rgb(10, 10, 10)
              fade_on_empty = true
              placeholder_text = <i>Password...</i>
              hide_input = false
              position = 0, -20
              halign = center
              valign = center
          }

          label {
              monitor =
              text = Hi # Consider making this configurable
              color = rgba(200, 200, 200, 1.0)
              font_size = 25
              font_family = Noto Sans # Consider making this configurable
              position = 0, 80
              halign = center
              valign = center
          }
        '';
    };

    # Export the lock script path for other modules (like hypridle) to use
    environment.sessionVariables.HYPRLOCK_SCRIPT = "${lockScript}/bin/lock-screen";

    # The hyprlock package is installed via the system suite.
  };
}