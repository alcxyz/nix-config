# modules/nixos/desktop/addons/hyprlock/default.nix
{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.desktop.addons.hyprlock;
  # Create the lock script that can optionally turn off displays
  lockScript = pkgs.writeShellScriptBin "lock-screen" ''
    ${cfg.package}/bin/hyprlock ${optionalString (!cfg.turnOffDisplaysOnLock) "& exit 0"}

    # If we're turning off displays, wait for specified delay then do it
    sleep ${toString cfg.displayOffDelay}
    ${pkgs.hyprland}/bin/hyprctl dispatch dpms off
  '';

in {
  options.desktop.addons.hyprlock = with types; {
    enable = mkBoolOpt false "Enable or disable the hyprlock screen locker.";

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

    wallpaper = {
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
        default = "/run/current-system/sw/share/backgrounds";
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

      blur = {
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

  config = mkIf cfg.enable {
    # Install packages including the custom lock script
    environment.systemPackages = [
      cfg.package
      lockScript
    ];

    # Create configuration for hyprlock
    home.configFile."hypr/hyprlock.conf" = {
      text = 
        let
          # Calculate the wallpaper path here - check useStandardDir first
          wallpaperPath = 
            if cfg.wallpaper.useStandardDir then # <--- Check useStandardDir FIRST
              if cfg.wallpaper.randomFromDir then
                "$(find ${cfg.wallpaper.standardDir} -type f \\( -name \"*.jpg\" -o -name \"*.jpeg\" -o -name \"*.png\" \\) | shuf -n 1)"
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
              text = Hi
              color = rgba(200, 200, 200, 1.0)
              font_size = 25
              font_family = Noto Sans
              position = 0, 80
              halign = center
              valign = center
          }
        '';
    };

    # Export the lock script path for other modules to use
    environment.sessionVariables.HYPRLOCK_SCRIPT = "${lockScript}/bin/lock-screen";
  };
}

