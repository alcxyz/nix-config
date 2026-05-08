{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
with lib;

let
  cfg = config.services.hyprlock;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;

  lockScript = pkgs.writeShellScriptBin "lock-screen" ''
    HYPRLOCK="${cfg.package}/bin/hyprlock"
    HYPRCTL="${pkgs.hyprland}/bin/hyprctl"
    if ${boolToString cfg.turnOffDisplaysOnLock}; then
      $HYPRLOCK &
      lock_pid="$!"
      ${pkgs.coreutils}/bin/sleep ${toString cfg.displayOffDelay}
      $HYPRCTL dispatch dpms off
      wait "$lock_pid"
    else
      exec $HYPRLOCK
    fi
  '';

  wallpaperPath =
    if cfg.wallpaper.useStandardDir then
      if cfg.wallpaper.randomFromDir then
        "$(${pkgs.findutils}/bin/find ${cfg.wallpaper.standardDir} -type f \\( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' \\) | ${pkgs.coreutils}/bin/shuf -n 1)"
      else
        "${cfg.wallpaper.standardDir}/${cfg.wallpaper.filename}"
    else if cfg.wallpaper.path == "screenshot" then "screenshot"
    else
      cfg.wallpaper.path;

  substituteConfig = text:
    let
      colorPlaceholders = [
        "@base00@" "@base01@" "@base02@" "@base03@"
        "@base04@" "@base05@" "@base06@" "@base07@"
        "@base08@" "@base09@" "@base0a@" "@base0b@"
        "@base0c@" "@base0d@" "@base0e@" "@base0f@"
      ];
      colorValues = [
        colors.base00 colors.base01 colors.base02 colors.base03
        colors.base04 colors.base05 colors.base06 colors.base07
        colors.base08 colors.base09 colors.base0A colors.base0B
        colors.base0C colors.base0D colors.base0E colors.base0F
      ];
      configPlaceholders = [
        "@WALLPAPER_PATH@"
        "@WALLPAPER_COLOR@"
        "@BLUR_PASSES@"
        "@BLUR_SIZE@"
        "@USER@"
      ];
      configValues = [
        wallpaperPath
        cfg.wallpaper.color
        (toString cfg.wallpaper.blur.passes)
        (toString cfg.wallpaper.blur.size)
        username
      ];
    in
    builtins.replaceStrings (colorPlaceholders ++ configPlaceholders) (colorValues ++ configValues) text;

  processedConfig = substituteConfig (builtins.readFile ./hyprlock.conf.template);
in {
  options.services.hyprlock = with types; {
    enable = mkEnableOption "Hyprlock screen locker";

    package = mkOption {
      type = package;
      default = pkgs.hyprlock;
      description = "The hyprlock package to use";
    };

    turnOffDisplaysOnLock = mkOption {
      type = bool;
      default = false;
      description = "Whether to turn off displays after manual locking";
    };

    displayOffDelay = mkOption {
      type = int;
      default = 10;
      description = "Seconds to wait before turning off displays after manual locking";
    };

    lockCommand = mkOption {
      type = str;
      default = "${lockScript}/bin/lock-screen";
      description = "Command to run to lock the screen";
    };

    wallpaper = {
      path = mkOption {
        type = str;
        default = "screenshot";
        description = "Wallpaper path, or screenshot to use a screenshot of the current desktop";
      };

      useStandardDir = mkOption {
        type = bool;
        default = false;
        description = "Whether to use the standard wallpapers directory";
      };

      standardDir = mkOption {
        type = str;
        default = "${config.home.homeDirectory}/.config/wallpapers";
        description = "Path to the standard wallpapers directory";
      };

      filename = mkOption {
        type = str;
        default = "lock.jpg";
        description = "Wallpaper filename in the standard directory";
      };

      randomFromDir = mkOption {
        type = bool;
        default = false;
        description = "Whether to use a random wallpaper from the standard directory";
      };

      color = mkOption {
        type = str;
        default = "rgb(${colors.base00})";
        description = "Background color to use behind the wallpaper";
      };

      blur = {
        size = mkOption {
          type = int;
          default = 7;
          description = "Blur size for the background";
        };

        passes = mkOption {
          type = int;
          default = 3;
          description = "Number of blur passes to apply";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ lockScript cfg.package ];
    xdg.configFile."hypr/hyprlock.conf".text = processedConfig;
    home.sessionVariables.HYPRLOCK_SCRIPT = "${lockScript}/bin/lock-screen";
  };
}
