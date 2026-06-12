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
  localConfigDir = "${config.programs.workspace.root}/infra/nix-config";
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
  laptopDisplayScript = pkgs.writeShellScript "hypr-laptop-display-autoswitch" ''
    set -eu

    export PATH=${makeBinPath [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.hyprland
      pkgs.jq
    ]}

    lid_closed() {
      for state in /proc/acpi/button/lid/*/state; do
        [ -r "$state" ] || continue
        grep -qi closed "$state" && return 0
      done
      return 1
    }

    monitors() {
      hyprctl monitors all -j 2>/dev/null || printf '[]\n'
    }

    first_output() {
      monitors | jq -r --arg pattern "$1" \
        '[.[] | select(.name | test($pattern)) | .name][0] // empty'
    }

    external_output() {
      monitors | jq -r \
        '[.[] | select(.name | test("^(eDP|LVDS)-") | not) | .name] | sort[0] // empty'
    }

    apply_display_state() {
      internal="$(first_output "^(eDP|LVDS)-")"
      external="$(external_output)"

      if [ -n "$external" ]; then
        hyprctl keyword monitor "$external, preferred, 0x0, 1" >/dev/null

        if [ -n "$internal" ]; then
          if lid_closed; then
            hyprctl keyword monitor "$internal, disable" >/dev/null
          else
            hyprctl keyword monitor "$internal, preferred, auto-right, 1" >/dev/null
          fi
        fi
      elif [ -n "$internal" ]; then
        hyprctl keyword monitor "$internal, preferred, 0x0, 1" >/dev/null
      fi
    }

    last_state=""
    while true; do
      state="$(monitors | jq -r '[.[] | .name] | sort | join(",")')"
      if lid_closed; then
        state="closed:$state"
      else
        state="open:$state"
      fi

      if [ "$state" != "$last_state" ]; then
        apply_display_state
        last_state="$state"
      fi

      sleep 2
    done
  '';
in {
  options.programs.hyprland.managed = {
    enable = mkEnableOption "Manage Hyprland-related user files (scripts, colors)";

    inputSensitivity = mkOption {
      type = types.nullOr types.float;
      default = null;
      description = "Optional Hyprland input sensitivity override in the range -1.0 to 1.0.";
    };

    laptopDisplayAutoSwitch.enable = mkEnableOption "automatic laptop display switching for external outputs and lid state";

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Host-specific Hyprland configuration appended after shared config.";
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

    home.file.".config/hypr/scripts/laptop_display_autoswitch.sh" = mkIf cfg.laptopDisplayAutoSwitch.enable {
      source = laptopDisplayScript;
      executable = true;
    };

    # Symlink hyprland configs directly to the repo checkout so edits take
    # effect immediately without a home-manager rebuild.
    xdg.configFile."hypr/hyprland.conf" = {
      force = true;
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/hyprland.conf";
    };
    xdg.configFile."hypr/binds.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/binds.conf";
    xdg.configFile."hypr/binds-scrolling.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/binds-scrolling.conf";
    xdg.configFile."hypr/binds-dwindle.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/binds-dwindle.conf";

    xdg.configFile."hypr/managed-overrides.conf".text = optionalString (cfg.inputSensitivity != null) ''
      input {
        sensitivity = ${toString cfg.inputSensitivity}
      }
    '';

    xdg.configFile."hypr/host.conf".text =
      cfg.extraConfig
      + optionalString cfg.laptopDisplayAutoSwitch.enable ''
        exec-once = ~/.config/hypr/scripts/laptop_display_autoswitch.sh
      '';

    # DMS user-editable configs — live symlinks so edits take effect immediately.
    # colors.conf and layout.conf are excluded: DMS generates them at runtime.
    xdg.configFile."hypr/dms/cursor.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/dms/cursor.conf";
    xdg.configFile."hypr/dms/windowrules.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/dms/windowrules.conf";
    xdg.configFile."hypr/dms/outputs.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/dms/outputs.conf";

    # Keep colors.conf generated from nix-colors
    xdg.configFile."hypr/colors.conf".text = ''
      general {
        col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
        col.inactive_border = 0xff${colors.base00}
      }
    '';
  };
}
