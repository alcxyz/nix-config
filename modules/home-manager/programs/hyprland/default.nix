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
  # Operator profiles use their live workspace checkout. Smaller profiles such
  # as madsil do not import the workspace module and retain the immutable flake
  # source behavior that predates the live-symlink optimization.
  localConfigDir =
    if lib.hasAttrByPath ["programs" "workspace" "root"] options
    then "${config.programs.workspace.root}/infra/nix-config"
    else toString configDir;
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
      local state
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

    internal_outputs() {
      monitors | jq -r \
        '[.[] | select(.name | test("^(eDP|LVDS)-")) | .name] | sort[]'
    }

    external_outputs() {
      monitors | jq -r \
        '[.[] | select((.name | test("^(eDP|LVDS)-")) | not) | .name] | sort[]'
    }

    monitor_fingerprint() {
      monitors | jq -c \
        '[.[] | {name, disabled, width, height, refreshRate, scale, availableModes}] | sort_by(.name)'
    }

    monitor_mode() {
      monitors | jq -r --arg name "$1" '
        ([.[] | select(.name == $name)][0] // {}) as $monitor
        | if (($monitor.description // "") | contains("49M2C8900")) then
            (
              ($monitor.availableModes // [])
              | map(
                  select(startswith("5120x1440@"))
                  | {
                      mode: (sub("Hz$"; "")),
                      refreshRate: (capture("@(?<refreshRate>[0-9.]+)Hz$").refreshRate | tonumber)
                    }
                )
              | sort_by(.refreshRate)
              | last.mode
            ) // "preferred"
          elif (
            try (
              (($monitor.availableModes // [])[0] // "")
              | capture("@(?<refreshRate>[0-9.]+)Hz$").refreshRate
              | tonumber
            ) catch 60
          ) < 50 then
            (
              ($monitor.availableModes // [])
              | map(
                  select(startswith("2560x1440@"))
                  | {
                      mode: (sub("Hz$"; "")),
                      refreshRate: (capture("@(?<refreshRate>[0-9.]+)Hz$").refreshRate | tonumber)
                    }
                  | select(.refreshRate >= 59)
                )
              | sort_by(.refreshRate)
              | last.mode
            ) // (
              ($monitor.availableModes // [])
              | map(
                  select(startswith("1920x1080@"))
                  | {
                      mode: (sub("Hz$"; "")),
                      refreshRate: (capture("@(?<refreshRate>[0-9.]+)Hz$").refreshRate | tonumber)
                    }
                  | select(.refreshRate >= 59)
                )
              | sort_by(.refreshRate)
              | last.mode
            ) // "preferred"
          else
            "preferred"
          end
      '
    }

    configure_monitor() {
      output="$1"
      position="$2"
      mode="$(monitor_mode "$output")"
      result="$(hyprctl eval "hl.monitor({ output = \"$output\", mode = \"$mode\", position = \"$position\", scale = \"1\", disabled = false })" 2>&1 || true)"
      if [ "$result" != ok ]; then
        hyprctl keyword monitor "$output, $mode, $position, 1" >/dev/null
      fi
    }

    disable_monitor() {
      output="$1"
      result="$(hyprctl eval "hl.monitor({ output = \"$output\", disabled = true })" 2>&1 || true)"
      if [ "$result" != ok ]; then
        hyprctl keyword monitor "$output, disable" >/dev/null
      fi
    }

    apply_display_state() {
      mapfile -t internals < <(internal_outputs)
      mapfile -t externals < <(external_outputs)

      if ((''${#externals[@]} > 0)); then
        primary="''${externals[0]}"
        configure_monitor "$primary" "0x0"

        for external in "''${externals[@]:1}"; do
          configure_monitor "$external" "auto-right"
        done

        for internal in "''${internals[@]}"; do
          if lid_closed; then
            disable_monitor "$internal"
          else
            configure_monitor "$internal" "auto-right"
          fi
        done

        hyprctl dispatch focusmonitor "$primary" >/dev/null || true
      elif ((''${#internals[@]} > 0)); then
        primary="$(first_output "^(eDP|LVDS)-")"
        configure_monitor "$primary" "0x0"

        for internal in "''${internals[@]:1}"; do
          configure_monitor "$internal" "auto-right"
        done

        hyprctl dispatch focusmonitor "$primary" >/dev/null || true
      fi
    }

    last_state=""
    while true; do
      state="$(monitor_fingerprint)"
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

    manageLegacyConfig = mkOption {
      type = types.bool;
      default = true;
      description = "Install the legacy hyprland.conf configuration and its fragments.";
    };

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

    # Symlink legacy Hyprland configs directly to the repo checkout so edits
    # take effect immediately without a home-manager rebuild.
    xdg.configFile."hypr/hyprland.conf" = mkIf cfg.manageLegacyConfig {
      force = true;
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/hyprland.conf";
    };
    xdg.configFile."hypr/binds.conf" = mkIf cfg.manageLegacyConfig {
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/binds.conf";
    };
    xdg.configFile."hypr/binds-scrolling.conf" = mkIf cfg.manageLegacyConfig {
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/binds-scrolling.conf";
    };
    xdg.configFile."hypr/binds-dwindle.conf" = mkIf cfg.manageLegacyConfig {
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/hypr/binds-dwindle.conf";
    };

    xdg.configFile."hypr/managed-overrides.conf" = mkIf cfg.manageLegacyConfig {
      text = optionalString (cfg.inputSensitivity != null) ''
        input {
          sensitivity = ${toString cfg.inputSensitivity}
        }
      '';
    };

    xdg.configFile."hypr/host.conf" = mkIf cfg.manageLegacyConfig {
      text =
        cfg.extraConfig
        + optionalString cfg.laptopDisplayAutoSwitch.enable ''
          exec-once = ${laptopDisplayScript}
        '';
    };

    # DMS generates colors.conf and layout.conf at runtime.
    xdg.configFile."hypr/dms/cursor.conf" = mkIf cfg.manageLegacyConfig {
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/dms/cursor.conf";
    };
    xdg.configFile."hypr/dms/windowrules.conf" = mkIf cfg.manageLegacyConfig {
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/dms/windowrules.conf";
    };
    xdg.configFile."hypr/dms/outputs.conf" = mkIf cfg.manageLegacyConfig {
      source = config.lib.file.mkOutOfStoreSymlink "${localConfigDir}/users/${username}/configs/dms/outputs.conf";
    };

    # Keep colors.conf generated from nix-colors
    xdg.configFile."hypr/colors.conf" = mkIf cfg.manageLegacyConfig {
      text = ''
        general {
          col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
          col.inactive_border = 0xff${colors.base00}
        }
      '';
    };

    # XPS starts this explicitly only for its normal desktop session. Keeping
    # the unit out of WantedBy prevents it from changing the dedicated couch
    # session's fixed display layout.
    systemd.user.services.hypr-laptop-display-autoswitch = mkIf cfg.laptopDisplayAutoSwitch.enable {
      Unit = {
        Description = "Adjust Hyprland outputs for laptop and dock state";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target"];
      };
      Service = {
        ExecStart = laptopDisplayScript;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
