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
  managedOverridesConfig = pkgs.writeText "hyprland-managed-overrides.conf" (
    optionalString (cfg.inputSensitivity != null) ''
      input {
        sensitivity = ${toString cfg.inputSensitivity}
      }
    ''
  );
  hostConfig = pkgs.writeText "hyprland-host.conf" (
    cfg.extraConfig
    + optionalString cfg.laptopDisplayAutoSwitch.enable ''
      exec-once = ${laptopDisplayScript}
    ''
  );
  colorsConfig = pkgs.writeText "hyprland-colors.conf" ''
    general {
      col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
      col.inactive_border = 0xff${colors.base00}
    }
  '';
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

    # Hyprland watches its configuration tree and reloads immediately. Home
    # Manager normally unlinks the old generation before linking the new one,
    # which exposes a briefly incomplete configuration to the running
    # compositor. Keep these links outside linkGeneration and replace each one
    # atomically instead. Repo-backed files still update live without a rebuild.
    home.activation.hyprlandLegacyConfig = mkIf cfg.manageLegacyConfig (
      lib.hm.dag.entryAfter ["linkGeneration"] ''
        hypr_dir=${escapeShellArg "${config.home.homeDirectory}/.config/hypr"}
        dms_dir="$hypr_dir/dms"
        mkdir -p "$hypr_dir" "$dms_dir"

        install_link() {
          source_path="$1"
          target_path="$2"

          if [ -L "$target_path" ] \
            && [ "$(readlink "$target_path")" = "$source_path" ]; then
            return
          fi

          temporary_path="$target_path.home-manager-new"
          rm -f "$temporary_path"
          ln -s "$source_path" "$temporary_path"
          mv -Tf "$temporary_path" "$target_path"
        }

        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/hypr/hyprland.conf"} "$hypr_dir/hyprland.conf"
        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/hypr/binds.conf"} "$hypr_dir/binds.conf"
        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/hypr/binds-scrolling.conf"} "$hypr_dir/binds-scrolling.conf"
        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/hypr/binds-dwindle.conf"} "$hypr_dir/binds-dwindle.conf"
        install_link ${escapeShellArg "${managedOverridesConfig}"} "$hypr_dir/managed-overrides.conf"
        install_link ${escapeShellArg "${hostConfig}"} "$hypr_dir/host.conf"
        install_link ${escapeShellArg "${colorsConfig}"} "$hypr_dir/colors.conf"
        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/dms/cursor.conf"} "$dms_dir/cursor.conf"
        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/dms/windowrules.conf"} "$dms_dir/windowrules.conf"
        install_link ${escapeShellArg "${localConfigDir}/users/${username}/configs/dms/outputs.conf"} "$dms_dir/outputs.conf"
      ''
    );

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
