# modules/home-manager/programs/hyprland/default.nix
{
  options,
  config,
  lib,
  pkgs,
  inputs,
  username,
  configDir,
  ...
}:
with lib; let
  cfg = config.programs.hyprland.managed;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
in {
  options.programs.hyprland.managed = {
    enable = mkEnableOption "Manage Hyprland-related user files (scripts, colors)";

    inputSensitivity = mkOption {
      type = types.nullOr types.float;
      default = null;
      description = "Optional Hyprland input sensitivity override in the range -1.0 to 1.0.";
    };
  };

  config = mkIf cfg.enable {
    # Shared wayland settings (cursor, GTK, ozone)
    programs.wayland-common.enable = true;

    home.file.".config/hypr/scripts/fkey_handler.sh" = {
      source = ./scripts/fkey_handler.sh;
      executable = true;
    };

    home.file.".config/hypr/scripts/dms_resume_watcher.sh" = {
      source = ./scripts/dms_resume_watcher.sh;
      executable = true;
    };

    # Symlink hyprland configs directly to the repo checkout so edits take
    # effect immediately without a home-manager rebuild.
    xdg.configFile."hypr/hyprland.conf" = {
      force = true;
      source = config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/hypr/hyprland.conf";
    };
    xdg.configFile."hypr/binds.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/hypr/binds.conf";
    xdg.configFile."hypr/binds-scrolling.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/hypr/binds-scrolling.conf";
    xdg.configFile."hypr/binds-dwindle.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/hypr/binds-dwindle.conf";

    xdg.configFile."hypr/managed-overrides.conf".text = optionalString (cfg.inputSensitivity != null) ''
      input {
        sensitivity = ${toString cfg.inputSensitivity}
      }
    '';

    # DMS user-editable configs — live symlinks so edits take effect immediately.
    # colors.conf and layout.conf are excluded: DMS generates them at runtime.
    xdg.configFile."hypr/dms/cursor.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dms/cursor.conf";
    xdg.configFile."hypr/dms/windowrules.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dms/windowrules.conf";
    xdg.configFile."hypr/dms/outputs.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dms/outputs.conf";

    # Keep colors.conf generated from nix-colors
    xdg.configFile."hypr/colors.conf".text = ''
      general {
        col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
        col.inactive_border = 0xff${colors.base00}
      }
    '';
  };
}
