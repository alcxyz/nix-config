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
  cfg = config.services.hyprlock;
  # Make nix-colors available for the default wallpaper color
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;

  lockScript = pkgs.writeShellScriptBin "lock-screen" ''
    HYPRLOCK="${cfg.package}/bin/hyprlock"
    HYPRCTL="${pkgs.hyprland}/bin/hyprctl"
    $HYPRLOCK ${optionalString (!cfg.turnOffDisplaysOnLock) "& exit 0"}
    ${pkgs.coreutils}/bin/sleep ${toString cfg.displayOffDelay}
    $HYPRCTL dispatch dpms off
  '';

in {
  options.services.hyprlock = with types; {
    enable = mkEnableOption "Hyprlock screen locker";
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
    lockCommand = mkOption {
      type = types.str;
      default = "${lockScript}/bin/lock-screen";
      description = "Command to run to lock the screen";
    };
    hyprctlCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprland}/bin/hyprctl";
      description = "Path to hyprctl command";
    };
    wallpaper = {
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
      useStandardDir = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use the standard wallpapers directory";
      };
      standardDir = mkOption {
        type = types.str;
        default = "${config.home.homeDirectory}/.config/wallpapers";
        description = "Path to the standard wallpapers directory";
      };
      filename = mkOption {
        type = types.str;
        default = "lock.jpg";
        description = "Wallpaper filename in the standard directory";
      };
      randomFromDir = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use a random wallpaper from the standard directory";
      };
      color = mkOption {
        type = types.str;
        default = "rgb(${colors.base00})";
        description = "Background color to use behind the wallpaper (e.g., rgba(25, 20, 20, 1.0) or rgb(f4c7c7))";
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
    home.packages = [ lockScript ];
    xdg.configFile."hypr/hyprlock.conf" = {
      text =
        let
          wallpaperPath =
            if cfg.wallpaper.useStandardDir then
              if cfg.wallpaper.randomFromDir then
                # Updated line with single quotes for -name patterns
                "$(${pkgs.findutils}/bin/find ${cfg.wallpaper.standardDir} -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' \) | ${pkgs.coreutils}/bin/shuf -n 1)"
              else
                "${cfg.wallpaper.standardDir}/${cfg.wallpaper.filename}"
            else if cfg.wallpaper.path == "screenshot" then "screenshot"
            else
              cfg.wallpaper.path;
        in
        ''
          background {
              monitor =
              path = ${wallpaperPath}
              color = ${cfg.wallpaper.color} # This will now use the (potentially themed) default or user override
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
              outer_color = rgb(151515) # Consider theming these too if desired
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
    home.sessionVariables.HYPRLOCK_SCRIPT = "${lockScript}/bin/lock-screen";
  };
}
