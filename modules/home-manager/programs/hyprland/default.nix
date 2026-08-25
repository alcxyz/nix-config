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
  # Live editing is convenient on development-only profiles, but a compositor
  # must also be able to consume an immutable snapshot. Otherwise unrelated
  # source-control operations can trigger a live Hyprland reload.
  configSourceDir =
    if cfg.liveConfigEditing && lib.hasAttrByPath ["programs" "workspace" "root"] options
    then "${config.programs.workspace.root}/infra/nix-config"
    else toString configDir;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
  toLua = generators.toLua {};
  managedOverridesConfig = pkgs.writeText "hyprland-managed-overrides.conf" (
    optionalString (cfg.inputSensitivity != null) ''
      input {
        sensitivity = ${toString cfg.inputSensitivity}
      }
    ''
    + optionalString (cfg.remotePointerInactiveTimeout != null || cfg.remotePointerHideOnTouch != null)
    ''
      cursor {
        ${optionalString (
        cfg.remotePointerInactiveTimeout != null
      ) "inactive_timeout = ${toString cfg.remotePointerInactiveTimeout}"}
        ${optionalString (
        cfg.remotePointerHideOnTouch != null
      ) "hide_on_touch = ${boolToString cfg.remotePointerHideOnTouch}"}
      }
    ''
  );
  managedOverridesLua = pkgs.writeText "hyprland-managed-overrides.lua" ''
    hl.config({
      ${optionalString (cfg.inputSensitivity != null) ''
      input = {
        sensitivity = ${toString cfg.inputSensitivity},
      },
    ''}
      ${
      optionalString
      (cfg.remotePointerInactiveTimeout != null || cfg.remotePointerHideOnTouch != null)
      ''
        cursor = {
          ${optionalString (
          cfg.remotePointerInactiveTimeout != null
        ) "inactive_timeout = ${toString cfg.remotePointerInactiveTimeout},"}
          ${optionalString (
          cfg.remotePointerHideOnTouch != null
        ) "hide_on_touch = ${boolToString cfg.remotePointerHideOnTouch},"}
        },
      ''
    }
    })
  '';
  inputDefaultsScript = pkgs.writeShellScript "hyprland-input-defaults" ''
    set -eu

    for _attempt in $(${pkgs.coreutils}/bin/seq 1 50); do
      if ${pkgs.hyprland}/bin/hyprctl eval ${escapeShellArg "hl.config({ input = { kb_layout = ${toLua (
      if cfg.inputLayouts == null
      then ""
      else cfg.inputLayouts
    )}, kb_options = ${toLua cfg.inputOptions} } })"} >/dev/null 2>&1; then
        ${pkgs.hyprland}/bin/hyprctl switchxkblayout all 0 >/dev/null
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "Hyprland was not ready for keyboard input defaults" >&2
    exit 1
  '';
  hostConfig = pkgs.writeText "hyprland-host.conf" (
    cfg.extraConfig
    + optionalString cfg.laptopDisplayAutoSwitch.enable ''
      exec-once = ${laptopDisplayScript}
    ''
  );
  hostLua = pkgs.writeText "hyprland-host.lua" (
    cfg.extraLuaConfig
    + optionalString cfg.laptopDisplayAutoSwitch.enable ''
      hl.on("hyprland.start", function()
        hl.exec_cmd(${toLua (toString laptopDisplayScript)})
      end)
    ''
  );
  colorsConfig = pkgs.writeText "hyprland-colors.conf" ''
    general {
      col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
      col.inactive_border = 0xff${colors.base00}
    }
  '';
  colorsLua = pkgs.writeText "hyprland-colors.lua" ''
    hl.config({
      general = {
        col = {
          active_border = {
            colors = { "0xff${colors.base0C}", "0xff${colors.base0D}" },
            angle = 270,
          },
          inactive_border = "0xff${colors.base00}",
        },
      },
    })
  '';
  immutableLuaConfig = pkgs.linkFarm "hyprland-lua-config" [
    {
      name = "hyprland.lua";
      path = "${configSourceDir}/users/${username}/configs/hypr/hyprland.lua";
    }
    {
      name = "binds.lua";
      path = "${configSourceDir}/users/${username}/configs/hypr/binds.lua";
    }
    {
      name = "binds-scrolling.lua";
      path = "${configSourceDir}/users/${username}/configs/hypr/binds-scrolling.lua";
    }
    {
      name = "binds-dwindle.lua";
      path = "${configSourceDir}/users/${username}/configs/hypr/binds-dwindle.lua";
    }
    {
      name = "managed-overrides.lua";
      path = managedOverridesLua;
    }
    {
      name = "host.lua";
      path = hostLua;
    }
    {
      name = "colors.lua";
      path = colorsLua;
    }
    {
      name = "dms/outputs.lua";
      path = "${configSourceDir}/users/${username}/configs/dms/outputs.lua";
    }
    {
      name = "dms/cursor.lua";
      path = "${configSourceDir}/users/${username}/configs/dms/cursor.lua";
    }
    {
      name = "dms/windowrules.lua";
      path = "${configSourceDir}/users/${username}/configs/dms/windowrules.lua";
    }
  ];
  luaConfigDir =
    if cfg.liveConfigEditing
    then "${config.home.homeDirectory}/.config/hypr"
    else immutableLuaConfig;
  laptopDisplayScript = pkgs.writeShellScript "hypr-laptop-display-autoswitch" ''
    set -eu

    export PATH=${
      makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.hyprland
        pkgs.jq
      ]
    }

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

    focus_monitor() {
      output="$1"
      result="$(hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = \"$output\" }))" 2>&1 || true)"
      if [ "$result" != ok ]; then
        hyprctl dispatch focusmonitor "$output" >/dev/null
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

        focus_monitor "$primary" || true
      elif ((''${#internals[@]} > 0)); then
        primary="$(first_output "^(eDP|LVDS)-")"
        configure_monitor "$primary" "0x0"

        for internal in "''${internals[@]:1}"; do
          configure_monitor "$internal" "auto-right"
        done

        focus_monitor "$primary" || true
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

    inputLayouts = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional comma-separated XKB layouts applied when the Hyprland graphical session starts.";
    };

    inputOptions = mkOption {
      type = types.str;
      default = "grp:alt_shift_toggle";
      description = "XKB options applied when the Hyprland graphical session starts.";
    };

    remotePointerInactiveTimeout = mkOption {
      type = types.nullOr (types.ints.between 0 20);
      default = null;
      description = ''
        Seconds to retain the cursor after remote pointer activity. Zero
        disables inactivity hiding; null leaves the compositor default intact.
      '';
    };

    remotePointerHideOnTouch = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Whether touch-classified input hides the cursor. Set false for remote
        pointer backends whose absolute axes can be classified as touch input.
      '';
    };

    laptopDisplayAutoSwitch.enable = mkEnableOption "automatic laptop display switching for external outputs and lid state";

    manageLegacyConfig = mkOption {
      type = types.bool;
      default = true;
      description = "Install the legacy hyprland.conf configuration and its fragments.";
    };

    manageLuaConfig = mkOption {
      type = types.bool;
      default = false;
      description = "Install the Hyprland Lua configuration and its modules.";
    };

    liveConfigEditing = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Link shared Hyprland and DMS configuration directly to the mutable
        workspace checkout. When disabled, the session starts directly from a
        complete immutable Nix-store tree and configuration updates take effect
        only when a new compositor session starts.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Host-specific Hyprland configuration appended after shared config.";
    };

    extraLuaConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Host-specific Hyprland Lua configuration loaded after shared config.";
    };
  };

  config = mkIf cfg.enable {
    assertions = optional (!cfg.liveConfigEditing) {
      assertion = cfg.manageLuaConfig;
      message = "Immutable Hyprland configuration currently requires programs.hyprland.managed.manageLuaConfig.";
    };

    # Shared wayland settings (cursor, GTK, ozone)
    programs.wayland-common.enable = true;

    # Hyprland does not discover hyprland.lua automatically. Override the
    # system desktop entry for Lua-managed users so UWSM always starts the
    # compositor with the declared main configuration instead of generating a
    # fallback hyprland.conf.
    xdg.dataFile."wayland-sessions/hyprland.desktop" = mkIf cfg.manageLuaConfig {
      text = ''
        [Desktop Entry]
        Name=Hyprland
        Comment=An intelligent dynamic tiling Wayland compositor
        Exec=${pkgs.coreutils}/bin/env HYPRLAND_CONFIG_DIR=${luaConfigDir} ${pkgs.hyprland}/bin/start-hyprland -- --config ${luaConfigDir}/hyprland.lua
        Type=Application
        DesktopNames=Hyprland
        Keywords=tiling;wayland;compositor;
      '';
    };

    home.file.".config/hypr/scripts/fkey_handler.sh" = {
      source = ./scripts/fkey_handler.sh;
      executable = true;
    };

    home.file.".config/hypr/scripts/dms_resume_watcher.sh" = {
      source = ./scripts/dms_resume_watcher.sh;
      executable = true;
    };

    home.file.".config/hypr/scripts/laptop_display_autoswitch.sh" =
      mkIf cfg.laptopDisplayAutoSwitch.enable
      {
        source = laptopDisplayScript;
        executable = true;
      };

    # Hyprland watches its configuration tree and reloads immediately. Home
    # Manager normally unlinks the old generation before linking the new one,
    # which exposes a briefly incomplete configuration to the running
    # compositor. Keep these links outside linkGeneration and replace each one
    # atomically instead. Workspace-backed files update live only when
    # liveConfigEditing is explicitly retained.
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

        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/hyprland.conf"} "$hypr_dir/hyprland.conf"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds.conf"} "$hypr_dir/binds.conf"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds-scrolling.conf"} "$hypr_dir/binds-scrolling.conf"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds-dwindle.conf"} "$hypr_dir/binds-dwindle.conf"
        install_link ${escapeShellArg "${managedOverridesConfig}"} "$hypr_dir/managed-overrides.conf"
        install_link ${escapeShellArg "${hostConfig}"} "$hypr_dir/host.conf"
        install_link ${escapeShellArg "${colorsConfig}"} "$hypr_dir/colors.conf"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/cursor.conf"} "$dms_dir/cursor.conf"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/windowrules.conf"} "$dms_dir/windowrules.conf"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/outputs.conf"} "$dms_dir/outputs.conf"
      ''
    );

    # Live-editing profiles retain atomic workspace links. Immutable profiles
    # deliberately leave ~/.config/hypr untouched: their desktop entry starts
    # directly from immutableLuaConfig, so activation cannot reload a running
    # compositor by changing a watched path.
    home.activation.hyprlandLuaConfig = mkIf (cfg.manageLuaConfig && cfg.liveConfigEditing) (
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

        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/hyprland.lua"} "$hypr_dir/hyprland.lua"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds.lua"} "$hypr_dir/binds.lua"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds-scrolling.lua"} "$hypr_dir/binds-scrolling.lua"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds-dwindle.lua"} "$hypr_dir/binds-dwindle.lua"
        install_link ${escapeShellArg "${managedOverridesLua}"} "$hypr_dir/managed-overrides.lua"
        install_link ${escapeShellArg "${hostLua}"} "$hypr_dir/host.lua"
        install_link ${escapeShellArg "${colorsLua}"} "$hypr_dir/colors.lua"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/outputs.lua"} "$dms_dir/outputs.lua"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/cursor.lua"} "$dms_dir/cursor.lua"
        install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/windowrules.lua"} "$dms_dir/windowrules.lua"

        provider="$(${pkgs.hyprland}/bin/hyprctl status -j 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '.configProvider // empty' 2>/dev/null || true)"
        if [ "$provider" = hyprlang ]; then
          # Keep the current legacy session complete during a live migration.
          # DMS must not leave that running compositor on Hyprland's generated
          # fallback merely because the next session is configured for Lua.
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/hyprland.conf"} "$hypr_dir/hyprland.conf"
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds.conf"} "$hypr_dir/binds.conf"
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds-scrolling.conf"} "$hypr_dir/binds-scrolling.conf"
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/hypr/binds-dwindle.conf"} "$hypr_dir/binds-dwindle.conf"
          install_link ${escapeShellArg "${managedOverridesConfig}"} "$hypr_dir/managed-overrides.conf"
          install_link ${escapeShellArg "${hostConfig}"} "$hypr_dir/host.conf"
          install_link ${escapeShellArg "${colorsConfig}"} "$hypr_dir/colors.conf"
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/cursor.conf"} "$dms_dir/cursor.conf"
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/windowrules.conf"} "$dms_dir/windowrules.conf"
          install_link ${escapeShellArg "${configSourceDir}/users/${username}/configs/dms/outputs.conf"} "$dms_dir/outputs.conf"
        else
          for legacy_path in \
            "$hypr_dir/hyprland.conf" \
            "$hypr_dir/binds.conf" \
            "$hypr_dir/binds-scrolling.conf" \
            "$hypr_dir/binds-dwindle.conf" \
            "$hypr_dir/managed-overrides.conf" \
            "$hypr_dir/host.conf" \
            "$hypr_dir/colors.conf" \
            "$dms_dir/cursor.conf" \
            "$dms_dir/windowrules.conf" \
            "$dms_dir/outputs.conf"; do
            [ -L "$legacy_path" ] && rm -f "$legacy_path"
          done
        fi
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

    systemd.user.services.hyprland-input-defaults = mkIf (cfg.inputLayouts != null) {
      Unit = {
        Description = "Apply Hyprland keyboard layout defaults";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target"];
      };
      Service = {
        Type = "oneshot";
        ExecStart = inputDefaultsScript;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
