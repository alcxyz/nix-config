# nix-config/modules/nixos/services/moonlight-client/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.moonlight-client;
  kdeConnectInputDefaults = import ../../../shared/kdeconnect-input.nix;
  kdeConnectExecutable = lib.getExe' pkgs.kdePackages.kdeconnect-kde "kdeconnectd";
  kdeConnectHyprlandInput =
    pkgs.callPackage ../kdeconnect-hyprland-input {};
  moonlightPackage = cfg.package.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ./patches/poll-absolute-mouse.patch
        ./patches/forward-media-keys.patch
      ];
  });

  modeStateDirectory = "/var/lib/moonlight-client";
  modeStateFile = "${modeStateDirectory}/session-mode";
  directDrmReturnModeFile = "${modeStateDirectory}/direct-drm-return-mode";
  directDrmKeyboardLayoutFile = "${modeStateDirectory}/direct-drm-keyboard-layout";
  directDrmKmsConfigFile = "${modeStateDirectory}/direct-drm-kms.json";
  qtConnectorName = connector:
    lib.replaceStrings
    [
      "HDMI-A-"
      "HDMI-B-"
      "-"
    ]
    [
      "HDMI"
      "HDMI"
      ""
    ]
    connector;
  directDrmFixedKmsConfigFile =
    if cfg.directDrmFixedOutput == null
    then null
    else
      pkgs.writeText "moonlight-direct-drm-fixed-kms.json" (
        builtins.toJSON {
          device = cfg.directDrmFixedOutput.device;
          outputs =
            [
              {
                name = qtConnectorName cfg.directDrmFixedOutput.connector;
                mode = cfg.directDrmFixedOutput.mode;
                primary = true;
                virtualIndex = 0;
              }
            ]
            ++ map
            (connector: {
              name = qtConnectorName connector;
              mode = "off";
            })
            cfg.directDrmFixedOutput.disabledConnectors;
        }
      );
  directDrmKmsConfigEnabled =
    cfg.directDrmAutoSelectOutput || cfg.directDrmFixedOutput != null;
  directDrmActiveKmsConfigFile =
    if cfg.directDrmAutoSelectOutput
    then directDrmKmsConfigFile
    else directDrmFixedKmsConfigFile;
  runtimeStateDirectory = "/run/moonlight-client";
  dynamicMonitorConfigFile = "${runtimeStateDirectory}/monitors.conf";
  mirrorStateFile = "${modeStateDirectory}/mirror-enabled";
  displayLayoutStateFile = "${modeStateDirectory}/display-layout";
  mergedDmsConfigDirectory = "${runtimeStateDirectory}/dms-merged";
  effectiveMergedDmsSettings =
    lib.recursiveUpdate (
      lib.optionalAttrs
      (cfg.sessionSplashCommand != null)
      {
        customPowerActionReboot = "${lib.getExe sessionPowerAction} reboot";
        customPowerActionPowerOff = "${lib.getExe sessionPowerAction} poweroff";
      }
    )
    cfg.mergedDmsSettings;
  mergedDmsSettingsFile = pkgs.writeText "dms-merged-settings.json" (
    builtins.toJSON effectiveMergedDmsSettings
  );
  mergedDmsCheatsheetFile = pkgs.writeText "xps-media-center.json" (
    builtins.toJSON {
      title = "XPS media center";
      provider = "xps-media-center";
      binds = {
        Controller = [
          {
            key = "Home A";
            desc = "Steam/Moonlight";
          }
          {
            key = "Home X";
            desc = "Remote Helium";
          }
          {
            key = "L3 R3";
            desc = "Back to Helium";
          }
          {
            key = "Minus Plus";
            desc = "Mirror toggle";
          }
          {
            key = "Minus X";
            desc = "Next layout";
          }
          {
            key = "Minus Y";
            desc = "Next audio";
          }
          {
            key = "Minus B";
            desc = "Show guide";
          }
        ];
        "Apps · ◆ = Super" = [
          {
            key = "◆ M";
            desc = "Steam/Moonlight";
          }
          {
            key = "◆ R";
            desc = "Remote Helium";
          }
          {
            key = "◆ B";
            desc = "Back to Helium";
          }
          {
            key = "◆ ⇧ M";
            desc = "Mirror toggle";
          }
          {
            key = "◆ ⇧ D";
            desc = "Next layout";
          }
          {
            key = "◆ ⇧ A";
            desc = "Next audio";
          }
          {
            key = "◆ V";
            desc = "New Helium";
          }
          {
            key = "Alt Enter";
            desc = "Terminal";
          }
          {
            key = "◆ Space";
            desc = "DMS search";
          }
        ];
        "Windows & audio" = [
          {
            key = "◆ Enter";
            desc = "Fullscreen";
          }
          {
            key = "◆ S";
            desc = "Floating";
          }
          {
            key = "◆ W";
            desc = "Close";
          }
          {
            key = "◆ 1–9";
            desc = "Active workspace";
          }
          {
            key = "◆ J/K";
            desc = "Previous / next";
          }
          {
            key = "◆ ⇧ 1–0";
            desc = "Move window";
          }
          {
            key = "F8 F9 F10";
            desc = "Volume controls";
          }
          {
            key = "Alt Shift";
            desc = "NO / US layout";
          }
          {
            key = "◆ H";
            desc = "Show guide";
          }
        ];
      };
    }
  );
  directStreamEnabled = cfg.streamHost != null && cfg.streamApplication != null;
  browserStreamEnabled = cfg.browserStreamHost != null && cfg.browserStreamApplication != null;
  browserSelectorEnabled = browserStreamEnabled && cfg.browserStreamSelectorApplication != null;
  browserSelectorHost =
    if cfg.browserStreamSelectorHost == null
    then cfg.browserStreamHost
    else cfg.browserStreamSelectorHost;
  browserSelectorLocalAddress =
    if cfg.browserStreamSelectorLocalAddress == null
    then cfg.browserStreamLocalAddress
    else cfg.browserStreamSelectorLocalAddress;
  browserSelectorRemoteAddress =
    if cfg.browserStreamSelectorRemoteAddress == null
    then cfg.browserStreamRemoteAddress
    else cfg.browserStreamSelectorRemoteAddress;
  directDrmStreamEnabled = cfg.enableDirectDrmStream && directStreamEnabled;
  directDrmBrowserEnabled = cfg.enableDirectDrmBrowserStreams && browserStreamEnabled;
  persistentDirectDrmBrowserDefault = cfg.defaultSessionMode == "direct-browser";
  compositorSessionCondition = pkgs.writeShellScript "nixbox-compositor-session-condition" ''
    mode="$(
      tr -d '[:space:]' \
        < ${lib.escapeShellArg modeStateFile} \
        2>/dev/null \
        || true
    )"
    case "''${mode%%:*}" in
      couch${
      lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
    }${lib.optionalString cfg.enableMergedProfile " | merged"})
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
  '';
  sessionModeSwitchEnabled =
    cfg.autoLoginUser
    != null
    && (cfg.desktopSessionCommand != null || directDrmStreamEnabled || directDrmBrowserEnabled);
  directModeInputShortcutsEnabled =
    cfg.enableDirectModeInputShortcuts
    && sessionModeSwitchEnabled
    && (directDrmStreamEnabled || directDrmBrowserEnabled);
  kdeConnectDirectInputEnabled =
    cfg.enableKdeConnect && (directDrmStreamEnabled || directDrmBrowserEnabled);
  dynamicExternalLayoutEnabled = cfg.autoLayoutExternalOutputs || cfg.autoMirrorExternalOutputs;
  defaultOutputMode =
    if dynamicExternalLayoutEnabled
    then lib.last cfg.autoLayoutSecondaryModes
    else cfg.outputMode;
  mirrorOutputMode =
    if cfg.mirrorOutputMode == null
    then cfg.outputMode
    else cfg.mirrorOutputMode;
  autoMirrorOutputMode =
    if cfg.mirrorOutputMode == null
    then ""
    else cfg.mirrorOutputMode;
  autoMirrorSecondaryPosition =
    if cfg.autoMirrorSecondaryPosition == null
    then cfg.autoLayoutSecondaryPosition
    else cfg.autoMirrorSecondaryPosition;
  autoMirrorTertiaryPosition =
    if cfg.autoMirrorTertiaryPosition == null
    then cfg.autoLayoutTertiaryPosition
    else cfg.autoMirrorTertiaryPosition;
  mirrorSourceOutputs = lib.unique (lib.attrValues cfg.mirrorOutputs);
  directDrmEnvironment =
    [
      "QT_QPA_PLATFORM=eglfs"
    ]
    ++ lib.optionals directDrmKmsConfigEnabled [
      "QT_QPA_EGLFS_INTEGRATION=eglfs_kms"
      "QT_QPA_EGLFS_KMS_CONFIG=${directDrmActiveKmsConfigFile}"
    ]
    ++ lib.optional (cfg.directDrmFixedOutput != null)
    "QT_QPA_EGLFS_ALWAYS_SET_MODE=1"
    ++ cfg.directDrmExtraEnvironment;
  mkMoonlightExecutable = name: profileDirectory:
    if profileDirectory == null
    then lib.getExe moonlightPackage
    else
      lib.getExe (
        pkgs.writeShellApplication {
          name = "moonlight-${name}";
          runtimeInputs = [pkgs.coreutils];
          text = ''
            install -d -m 0700 \
              ${lib.escapeShellArg "${profileDirectory}/config"} \
              ${lib.escapeShellArg "${profileDirectory}/cache"} \
              ${lib.escapeShellArg "${profileDirectory}/data"}
            export XDG_CONFIG_HOME=${lib.escapeShellArg "${profileDirectory}/config"}
            export XDG_CACHE_HOME=${lib.escapeShellArg "${profileDirectory}/cache"}
            export XDG_DATA_HOME=${lib.escapeShellArg "${profileDirectory}/data"}
            exec ${lib.getExe moonlightPackage} "$@"
          '';
        }
      );
  defaultMoonlightExecutable = mkMoonlightExecutable "default" null;
  selectorMoonlightExecutable = mkMoonlightExecutable "browser-selector" cfg.browserStreamSelectorProfileDirectory;
  mkMoonlightInvocation = executable: extraEnvironment: extraArguments: host: application:
    lib.escapeShellArgs (
      [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
      ]
      ++ extraEnvironment
      ++ [
        executable
        "stream"
      ]
      ++ cfg.streamArguments
      ++ extraArguments
      ++ [
        host
        application
      ]
    );
  moonlightInvocation =
    if directStreamEnabled
    then mkMoonlightInvocation defaultMoonlightExecutable [] [] cfg.streamHost cfg.streamApplication
    else
      lib.escapeShellArgs [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
        defaultMoonlightExecutable
      ];
  directDrmMoonlightInvocation = lib.optionalString directDrmStreamEnabled (
    mkMoonlightInvocation defaultMoonlightExecutable directDrmEnvironment cfg.directDrmStreamArguments
    cfg.streamHost
    cfg.streamApplication
  );
  browserMoonlightInvocation = lib.optionalString browserStreamEnabled (
    mkMoonlightInvocation defaultMoonlightExecutable (
      [
        "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
        "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
        "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
      ]
      ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
    )
    cfg.browserStreamArguments
    cfg.browserStreamHost
    cfg.browserStreamApplication
  );
  browserSelectorMoonlightInvocation = lib.optionalString browserSelectorEnabled (
    mkMoonlightInvocation selectorMoonlightExecutable (
      [
        "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
        "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
        "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
      ]
      ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
    )
    cfg.browserStreamArguments
    browserSelectorHost
    cfg.browserStreamSelectorApplication
  );
  directDrmBrowserMoonlightInvocation = lib.optionalString directDrmBrowserEnabled (
    mkMoonlightInvocation defaultMoonlightExecutable (
      [
        "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
        "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
        "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
      ]
      ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
      ++ directDrmEnvironment
    )
    cfg.browserStreamArguments
    cfg.browserStreamHost
    cfg.browserStreamApplication
  );
  directDrmBrowserSelectorMoonlightInvocation =
    lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled)
    (
      mkMoonlightInvocation selectorMoonlightExecutable (
        [
          "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
          "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
          "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
        ]
        ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
        ++ directDrmEnvironment
      )
      cfg.browserStreamArguments
      browserSelectorHost
      cfg.browserStreamSelectorApplication
    );
  superviseMoonlightWindow = targetWorkspace: ''
    seen_window=0
    startup_window_checks=0
    missing_window_checks=0
    moonlight_address=""
    placed_moonlight_address=""

    terminate_moonlight() {
      kill "$moonlight_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$moonlight_pid" >/dev/null 2>&1 || true
    }

    # systemd stops the supervising shell first. Explicitly reap Moonlight so
    # a restart cannot leave the old client holding SDL input/audio resources
    # while a replacement client is launched.
    trap 'terminate_moonlight; exit 0' HUP INT TERM

    while kill -0 "$moonlight_pid" >/dev/null 2>&1; do
      moonlight_address="$(
        hyprctl -j clients 2>/dev/null \
          | jq -r --argjson pid "$moonlight_pid" '
              first(
                .[]
                | select(
                    .mapped
                    and .pid == $pid
                  )
                | .address
              ) // empty
            '
      )"
      if [ -n "$moonlight_address" ]; then
        # Moonlight can replace its XWayland window while the renderer is
        # initialized. Place each newly observed address, not just the first
        # transient window, or concurrent client starts can leave the final
        # window tiled on whichever workspace was focused last.
        if [ "$moonlight_address" != "$placed_moonlight_address" ]; then
          hyprctl dispatch movetoworkspacesilent \
            ${toString targetWorkspace},"address:$moonlight_address" \
            >/dev/null 2>&1 || true
          if [ "$seen_window" -eq 0 ]; then
            hyprctl dispatch workspace ${toString targetWorkspace} \
              >/dev/null 2>&1 || true
            hyprctl dispatch focuswindow "address:$moonlight_address" \
              >/dev/null 2>&1 || true
          fi
          placed_moonlight_address="$moonlight_address"
        fi
        seen_window=1
        startup_window_checks=0
        missing_window_checks=0
      elif [ "$seen_window" -eq 1 ]; then
        missing_window_checks=$((missing_window_checks + 1))
        if [ "$missing_window_checks" -ge 5 ]; then
          terminate_moonlight
          break
        fi
      else
        startup_window_checks=$((startup_window_checks + 1))
        if [ "$startup_window_checks" -ge 30 ]; then
          terminate_moonlight
          break
        fi
      fi
      sleep 1
    done

    status=0
    wait "$moonlight_pid" || status=$?
    trap - HUP INT TERM
  '';
  streamEndpointPolicyEnabled = cfg.streamLocalAddress != null && cfg.streamRemoteAddress != null;
  browserStreamEndpointPolicyEnabled =
    cfg.browserStreamLocalAddress != null && cfg.browserStreamRemoteAddress != null;
  browserSelectorEndpointPolicyEnabled =
    browserSelectorLocalAddress != null && browserSelectorRemoteAddress != null;
  browserStreamReadinessHosts =
    if browserStreamEndpointPolicyEnabled
    then
      lib.unique (
        if cfg.browserStreamEndpointMode == "lan-only"
        then [cfg.browserStreamLocalAddress]
        else if cfg.browserStreamEndpointMode == "remote-only"
        then [cfg.browserStreamRemoteAddress]
        else [
          cfg.browserStreamLocalAddress
          cfg.browserStreamRemoteAddress
        ]
      )
    else lib.optional browserStreamEnabled cfg.browserStreamHost;
  streamReadinessHosts =
    if streamEndpointPolicyEnabled
    then
      lib.unique (
        if cfg.streamEndpointMode == "lan-only"
        then [cfg.streamLocalAddress]
        else if cfg.streamEndpointMode == "remote-only"
        then [cfg.streamRemoteAddress]
        else [
          cfg.streamLocalAddress
          cfg.streamRemoteAddress
        ]
      )
    else lib.optional (cfg.streamReadinessHost != null) cfg.streamReadinessHost;
  reconcileMoonlightEndpoints = pkgs.writeShellApplication {
    name = "reconcile-moonlight-endpoints";
    runtimeInputs = [pkgs.python3];
    text = ''
      exec python3 ${./reconcile-endpoints.py} "$@"
    '';
  };
  mkMoonlightEndpointSetup = name: profileDirectory: reconcileStream: reconcileBrowser: selector: let
    reconciliationEnabled =
      (reconcileStream && streamEndpointPolicyEnabled)
      || (
        reconcileBrowser
        && (
          if selector
          then browserSelectorEndpointPolicyEnabled
          else browserStreamEndpointPolicyEnabled
        )
      );
  in
    pkgs.writeShellApplication {
      name = "moonlight-endpoint-setup-${name}";
      text = ''
        ${lib.optionalString reconciliationEnabled ''
          config_file=${
            if profileDirectory == null
            then ''"$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"''
            else lib.escapeShellArg "${profileDirectory}/config/Moonlight Game Streaming Project/Moonlight.conf"
          }
        ''}
        ${lib.optionalString (reconcileStream && streamEndpointPolicyEnabled) ''
          ${lib.getExe reconcileMoonlightEndpoints} \
            "$config_file" \
            ${lib.escapeShellArg cfg.streamHost} \
            ${lib.escapeShellArg cfg.streamEndpointMode} \
            ${lib.escapeShellArg cfg.streamLocalAddress} \
            ${lib.escapeShellArg cfg.streamRemoteAddress}
        ''}
        ${lib.optionalString (reconcileBrowser && browserStreamEndpointPolicyEnabled) ''
          ${lib.getExe reconcileMoonlightEndpoints} \
            "$config_file" \
            ${lib.escapeShellArg (
            if selector
            then browserSelectorHost
            else cfg.browserStreamHost
          )} \
            ${lib.escapeShellArg cfg.browserStreamEndpointMode} \
            ${
            lib.escapeShellArg (
              if selector
              then browserSelectorLocalAddress
              else cfg.browserStreamLocalAddress
            )
          } \
            ${
            lib.escapeShellArg (
              if selector
              then browserSelectorRemoteAddress
              else cfg.browserStreamRemoteAddress
            )
          } ${lib.optionalString selector ''
            ${
              lib.escapeShellArg (
                if cfg.browserStreamSelectorPort == null
                then ""
                else toString cfg.browserStreamSelectorPort
              )
            } \
            ${lib.escapeShellArg cfg.browserStreamHost}
          ''}
        ''}
      '';
    };
  moonlightEndpointSetup = mkMoonlightEndpointSetup "default" null true true false;
  browserSelectorEndpointSetup =
    mkMoonlightEndpointSetup "browser-selector" cfg.browserStreamSelectorProfileDirectory false true
    true;
  browserSelectorPair = pkgs.writeShellApplication {
    name = "couch-moonlight-pair-private";
    text = ''
      if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]{4}$ ]]; then
        echo "usage: couch-moonlight-pair-private FOUR_DIGIT_PIN" >&2
        exit 2
      fi
      exec ${pkgs.coreutils}/bin/env \
        QT_QPA_PLATFORM=${
        lib.escapeShellArg (
          if cfg.enableCompositedSession
          then cfg.moonlightPlatform
          else "offscreen"
        )
      } \
        ${selectorMoonlightExecutable} pair --pin "$1" ${
        lib.escapeShellArg (
          if browserSelectorLocalAddress == null
          then browserSelectorHost
          else
            browserSelectorLocalAddress
            + lib.optionalString (
              cfg.browserStreamSelectorPort != null
            ) ":${toString cfg.browserStreamSelectorPort}"
        )
      }
    '';
  };

  activeKeyboardLayout = pkgs.writeShellApplication {
    name = "couch-active-keyboard-layout";
    runtimeInputs =
      [pkgs.coreutils]
      ++ lib.optionals cfg.enableCompositedSession [
        pkgs.hyprland
        pkgs.jq
      ];
    text =
      if !cfg.enableCompositedSession
      then ''
        configured_layouts=${lib.escapeShellArg cfg.keyboardLayouts}
        printf '%s\n' "''${configured_layouts%%,*}"
      ''
      else ''
        configured_layouts=${lib.escapeShellArg cfg.keyboardLayouts}
        fallback_layout="''${configured_layouts%%,*}"
        active_keymap=""

        # Give hot-plugged USB receivers a brief chance to appear at graphical
        # login. Hyprland's "main" keyboard can remain the internal laptop
        # device even while an external keyboard is the one being used.
        for attempt in $(seq 1 20); do
          devices="$(hyprctl -j devices 2>/dev/null || true)"
          if printf '%s' "$devices" \
            | jq -e 'type == "object" and (.keyboards | type == "array")' \
              >/dev/null 2>&1; then
            while IFS= read -r keyboard_name; do
              keyboard_name="$(printf '%s' "$keyboard_name" | tr '[:upper:]' '[:lower:]')"
              case "$keyboard_name" in
                ${lib.concatStringsSep "\n              " (
          lib.flatten (
            lib.mapAttrsToList (
              layout: matches:
                map (
                  match: "*${lib.escapeShellArg (lib.toLower match)}*) printf '%s\\n' ${lib.escapeShellArg layout}; exit 0 ;;"
                )
                matches
            )
            cfg.keyboardLayoutDeviceOverrides
          )
        )}
              esac
            done < <(printf '%s' "$devices" | jq -r '.keyboards[].name')

            active_keymap="$(
              printf '%s' "$devices" \
                | jq -r 'first(.keyboards[] | select(.main)).active_keymap // empty'
            )"
            if [ "$attempt" -ge 8 ] && [ -n "$active_keymap" ]; then
              break
            fi
          fi
          sleep 0.25
        done

        case "$active_keymap" in
          *Norwegian*) printf '%s\n' no ;;
          *Russian*) printf '%s\n' ru ;;
          *"English (US)"*) printf '%s\n' us ;;
          *) printf '%s\n' "$fallback_layout" ;;
        esac
      '';
  };

  directDrmOutputSnapshot = pkgs.writeShellApplication {
    name = "moonlight-direct-drm-output-snapshot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        for socket_path in "$runtime_dir"/hypr/*/.socket.sock; do
          if [ -S "$socket_path" ]; then
            candidate_signature="$(basename "$(dirname "$socket_path")")"
            if HYPRLAND_INSTANCE_SIGNATURE="$candidate_signature" \
              XDG_RUNTIME_DIR="$runtime_dir" \
              hyprctl -j monitors >/dev/null 2>&1; then
              export HYPRLAND_INSTANCE_SIGNATURE="$candidate_signature"
              break
            fi
          fi
        done
      fi
      export XDG_RUNTIME_DIR="$runtime_dir"

      monitors="$(hyprctl -j monitors 2>/dev/null || true)"
      if ! jq -e 'type == "array"' <<<"$monitors" >/dev/null 2>&1; then
        echo "Could not query the active Hyprland output" >&2
        exit 1
      fi
      monitor="$(
        jq -c '
          ([.[] | select(.focused == true and .dpmsStatus == true)][0]
            // [.[] | select(.dpmsStatus == true)][0]
            // empty)
        ' <<<"$monitors"
      )"
      if [ -z "$monitor" ] || [ "$monitor" = null ]; then
        echo "No powered Hyprland output is available for direct DRM" >&2
        exit 1
      fi

      output="$(jq -r '.name' <<<"$monitor")"
      width="$(jq -r '.width' <<<"$monitor")"
      height="$(jq -r '.height' <<<"$monitor")"
      case "$width:$height" in
        *[!0-9:]* | :* | *:) echo "Invalid direct DRM output dimensions" >&2; exit 1 ;;
      esac

      connector_path=""
      for candidate in /sys/class/drm/card*-"$output"; do
        if [ -d "$candidate" ]; then
          connector_path="$candidate"
          break
        fi
      done
      if [ -z "$connector_path" ]; then
        echo "Could not map Hyprland output $output to a DRM connector" >&2
        exit 1
      fi

      connector_node="$(basename "$connector_path")"
      card_name="''${connector_node%%-*}"
      device="/dev/dri/$card_name"
      if [ ! -c "$device" ]; then
        echo "Direct DRM device $device is unavailable" >&2
        exit 1
      fi

      outputs='[]'
      for status_path in /sys/class/drm/"$card_name"-*/status; do
        [ -f "$status_path" ] || continue
        if [ "$(tr -d '[:space:]' < "$status_path")" != connected ]; then
          continue
        fi
        connector="$(basename "''${status_path%/status}")"
        connector="''${connector#"$card_name"-}"
        qt_connector="''${connector//-/}"
        case "$qt_connector" in
          HDMIA*) qt_connector="HDMI''${qt_connector#HDMIA}" ;;
          HDMIB*) qt_connector="HDMI''${qt_connector#HDMIB}" ;;
        esac
        if [ "$connector" = "$output" ]; then
          outputs="$(
            jq \
              --arg name "$qt_connector" \
              --arg mode "''${width}x''${height}" \
              '. + [{
                name: $name,
                mode: $mode,
                primary: true,
                virtualIndex: 0
              }]' \
              <<<"$outputs"
          )"
        else
          outputs="$(
            jq \
              --arg name "$qt_connector" \
              '. + [{name: $name, mode: "off"}]' \
              <<<"$outputs"
          )"
        fi
      done

      if ! jq -e 'any(.[]; .primary == true)' <<<"$outputs" >/dev/null; then
        echo "Selected direct DRM output disappeared during snapshot" >&2
        exit 1
      fi

      temporary="$(mktemp ${lib.escapeShellArg "${directDrmKmsConfigFile}.XXXXXX"})"
      trap 'rm -f "$temporary"' EXIT
      jq -n \
        --arg device "$device" \
        --argjson outputs "$outputs" \
        '{device: $device, outputs: $outputs}' \
        > "$temporary"
      chmod 0644 "$temporary"
      mv "$temporary" ${lib.escapeShellArg directDrmKmsConfigFile}
      trap - EXIT
      printf 'Direct DRM output: %s on %s at %sx%s\n' \
        "$output" "$device" "$width" "$height"
    '';
  };

  directDrmAudioOutputSetup = pkgs.writeShellApplication {
    name = "moonlight-direct-drm-audio-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.pipewire
      pkgs.wireplumber
    ];
    text = ''
      output="$(
        jq -r \
          '[.outputs[] | select(.primary == true)][0].name // empty' \
          ${lib.escapeShellArg directDrmActiveKmsConfigFile} \
          2>/dev/null \
          || true
      )"
      case "$output" in
        ${lib.concatStringsSep "\n        " (
        lib.mapAttrsToList (
          connector: description: "${
            lib.escapeShellArg (qtConnectorName connector)
          }) target=${lib.escapeShellArg description} ;;"
        )
        cfg.directDrmAudioOutputByConnector
      )}
        *) exit 0 ;;
      esac

      for ((attempt = 0; attempt < 20; attempt++)); do
        target_id="$(
          pw-dump 2>/dev/null \
            | jq -r --arg target "$target" '
                [
                  .[]
                  | select(
                      .type == "PipeWire:Interface:Node"
                      and (.info.props["media.class"] // "") == "Audio/Sink"
                      and (
                        (.info.props["node.description"] // "") == $target
                        or (.info.props["node.nick"] // "") == $target
                        or (.info.props["node.name"] // "") == $target
                      )
                    )
                ][0].id // empty
              ' \
            || true
        )"
        if [ -n "$target_id" ]; then
          wpctl set-default "$target_id"
          wpctl set-volume "$target_id" ${lib.escapeShellArg "${toString cfg.audioOutputStartupVolumePercent}%"}
          printf 'Direct DRM audio output: %s\n' "$target"
          exit 0
        fi
        sleep 0.25
      done

      echo "Direct DRM audio output is unavailable: $target" >&2
      exit 1
    '';
  };

  displayModeSetup = pkgs.writeShellApplication {
    name = "moonlight-display-mode";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      target_spec=${lib.escapeShellArg cfg.outputMode}
      target_dimensions="''${target_spec%@*}"
      target_refresh="''${target_spec##*@}"
      target_width="''${target_dimensions%x*}"
      target_height="''${target_dimensions#*x}"
      external_seen=0

      if [[ "$target_width" =~ ^[0-9]+$ ]] \
        && [[ "$target_height" =~ ^[0-9]+$ ]] \
        && [[ "$target_refresh" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        for ((attempt = 0; attempt < 20; attempt++)); do
          monitors="$(hyprctl -j monitors 2>/dev/null || true)"
          if jq -e 'any(.[]; .name != "eDP-1" and .name != "LVDS-1")' \
            <<<"$monitors" >/dev/null; then
            external_seen=1
          fi

          if jq -e \
              --argjson width "$target_width" \
              --argjson height "$target_height" \
              --argjson refresh "$target_refresh" \
              'any(.[]; .name != "eDP-1" and .name != "LVDS-1"
                and .width == $width and .height == $height
                and ((.refreshRate - $refresh) | fabs) < 1.0)' \
              <<<"$monitors" >/dev/null; then
            exit 0
          fi
          sleep 0.25
        done
      fi

      ${lib.optionalString (cfg.fallbackOutputMode != null) ''
        if [ "$external_seen" -eq 1 ]; then
          hyprctl keyword monitor ${lib.escapeShellArg ", ${cfg.fallbackOutputMode}, auto, ${toString cfg.outputScale}"}
        fi
      ''}
    '';
  };

  hdmiAudioSetup = pkgs.writeShellApplication {
    name = "moonlight-hdmi-audio";
    runtimeInputs = [
      pkgs.gawk
      pkgs.pulseaudio
      pkgs.systemd
    ];
    text = ''
      systemctl --user start pipewire.service wireplumber.service pipewire-pulse.socket \
        >/dev/null 2>&1 || true

      for ((attempt = 0; attempt < 20; attempt++)); do
        while read -r card; do
          pactl set-card-profile "$card" output:hdmi-stereo >/dev/null 2>&1 || true
        done < <(pactl list short cards 2>/dev/null | awk '{ print $2 }')

        sink="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /hdmi/ { print $2; exit }')"
        if [ -n "$sink" ]; then
          pactl set-default-sink "$sink"
          exit 0
        fi
        sleep 0.5
      done

      exit 1
    '';
  };

  moonlightSession = pkgs.writeShellApplication {
    name = "moonlight-session";
    runtimeInputs = [
      moonlightPackage
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text =
      if cfg.relaunchOnExit
      then ''
        ${lib.getExe moonlightEndpointSetup}
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        while true; do
          ${moonlightInvocation} &
          moonlight_pid=$!
          ${superviseMoonlightWindow 1}
          sleep 1
        done
      ''
      else ''
        ${lib.getExe moonlightEndpointSetup}
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        ${moonlightInvocation} &
        moonlight_pid=$!
        ${superviseMoonlightWindow 1}
        exit "$status"
      '';
  };

  couchBrowser = pkgs.writeShellApplication {
    name = "couch-browser";
    runtimeInputs = [pkgs.hyprland];
    text = ''
      hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
      exec ${lib.getExe cfg.browserPackage} \
        --class=CouchBrowser \
        --user-data-dir="$HOME/.local/share/${cfg.browserProfileDirectory}" \
        --ozone-platform=x11 \
        --password-store=basic \
        --force-device-scale-factor=${toString cfg.browserScaleFactor} \
        "$@"
    '';
  };

  couchBrowserNewWindow = pkgs.writeShellApplication {
    name = "couch-browser-new-window";
    text = ''
      exec ${lib.getExe couchBrowser} --new-window "$@"
    '';
  };

  couchBrowserStartup = pkgs.writeShellApplication {
    name = "couch-browser-startup";
    runtimeInputs = [
      pkgs.netcat-openbsd
      pkgs.systemd
    ];
    text = ''
      # Hyprland launches exec-once commands concurrently. Import the current
      # compositor environment here before systemd starts the supervised
      # Moonlight unit, so its hyprctl window health check cannot race the
      # session-wide environment import.
      systemctl --user import-environment \
        WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP \
        DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true

      remote_hosts=(${lib.concatMapStringsSep " " lib.escapeShellArg browserStreamReadinessHosts})

      for ((attempt = 0; attempt < ${toString cfg.browserStartupTimeout}; attempt++)); do
        for host in "''${remote_hosts[@]}"; do
          if nc -z -w 1 "$host" ${toString cfg.streamReadinessPort} \
            >/dev/null 2>&1; then
            systemctl --user reset-failed couch-moonlight-browser-stream.service \
              >/dev/null 2>&1 || true
            if systemctl --user start couch-moonlight-browser-stream.service; then
              exit 0
            fi
          fi
        done
        sleep 1
      done

      ${
        if cfg.enableLocalBrowser
        then "exec ${lib.getExe couchBrowser}"
        else ''
          echo "Remote browser did not become ready and the local fallback is disabled" >&2
          exit 1
        ''
      }
    '';
  };

  couchTerminal = pkgs.writeShellApplication {
    name = "couch-terminal";
    runtimeInputs = [pkgs.hyprland];
    text = ''
      hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
      exec ${lib.getExe cfg.terminalPackage}
    '';
  };

  couchFallbackBrowser = lib.optionalAttrs (cfg.fallbackBrowserPackage != null) {
    package = pkgs.writeShellApplication {
      name = "couch-browser-fallback";
      runtimeInputs = [pkgs.hyprland];
      text = ''
        hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        exec ${lib.getExe cfg.fallbackBrowserPackage} \
          --user-data-dir="$HOME/.local/share/${cfg.fallbackBrowserProfileDirectory}" \
          --ozone-platform=x11 \
          --password-store=basic \
          --force-device-scale-factor=${toString cfg.browserScaleFactor} \
          "$@"
      '';
    };
  };

  protectedBrowserPasswordPrompt = pkgs.writeShellApplication {
    name = "couch-protected-browser-password";
    runtimeInputs = [pkgs.zenity];
    text = ''
      export GDK_BACKEND=x11
      case "''${1:-unlock}" in
        create)
          prompt=${lib.escapeShellArg "Choose a password for the protected ${cfg.protectedBrowserName} profile"}
          ;;
        confirm)
          prompt=${lib.escapeShellArg "Confirm the password for the protected ${cfg.protectedBrowserName} profile"}
          ;;
        *)
          prompt=${lib.escapeShellArg "Enter the password for the protected ${cfg.protectedBrowserName} profile"}
          ;;
      esac
      exec zenity \
        --password \
        --title=${lib.escapeShellArg "Unlock ${cfg.protectedBrowserName}"} \
        --text="$prompt"
    '';
  };

  protectedBrowserSession = pkgs.writeShellApplication {
    name = "${cfg.protectedBrowserCommandName}-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gocryptfs
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
      pkgs.util-linux
      pkgs.zenity
    ];
    text = ''
      # FUSE mounts on NixOS must use the privileged wrappers, not the
      # unwrapped fusermount binaries from a package dependency.
      export PATH="/run/wrappers/bin:$PATH"

      cipher_directory="$HOME/.local/share/${cfg.protectedBrowserEncryptedDirectory}"
      runtime_directory="''${XDG_RUNTIME_DIR:-/run/user/$UID}/${cfg.protectedBrowserRuntimeDirectory}"
      mountpoint="$runtime_directory/profile"
      mounted_here=false
      initial_password=""
      placement_pid=""
      launch_workspace="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // 2')"

      focus_launch_workspace() {
        hyprctl dispatch workspace "$launch_workspace" >/dev/null 2>&1 || true
      }

      place_protected_windows() {
        event_socket="''${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
        socat -u "UNIX-CONNECT:$event_socket" - 2>/dev/null |
          while IFS= read -r event; do
            case "$event" in
              openwindow\>\>*) ;;
              *) continue ;;
            esac

            window_data="''${event#openwindow>>}"
            IFS=, read -r address _workspace window_class window_title <<<"$window_data"
            if { [ "$window_class" = zenity ] \
                && [[ "$window_title" == *${lib.escapeShellArg cfg.protectedBrowserName}* ]]; } \
              || [ "$window_class" = ProtectedBrowser ]; then
              address="0x''${address#0x}"
              hyprctl dispatch movetoworkspacesilent \
                "$launch_workspace,address:$address" >/dev/null 2>&1 || true
              hyprctl dispatch focuswindow "address:$address" >/dev/null 2>&1 || true
              hyprctl dispatch centerwindow >/dev/null 2>&1 || true
            fi
          done
      }

      show_error() {
        GDK_BACKEND=x11 zenity \
          --error \
          --title=${lib.escapeShellArg cfg.protectedBrowserName} \
          --text="$1" >/dev/null 2>&1 || true
      }

      # shellcheck disable=SC2329 # Invoked by the trap below.
      cleanup() {
        if [ -n "$placement_pid" ]; then
          kill "$placement_pid" 2>/dev/null || true
          wait "$placement_pid" 2>/dev/null || true
        fi
        if [ "$mounted_here" = true ] && mountpoint -q "$mountpoint"; then
          if ! /run/wrappers/bin/fusermount3 -u "$mountpoint"; then
            show_error ${lib.escapeShellArg "${cfg.protectedBrowserName} has closed, but its encrypted profile is still mounted. Close any remaining browser processes and run this launcher again to finish locking it."}
          fi
        fi
      }
      trap cleanup EXIT
      trap 'exit 0' HUP INT TERM

      install -d -m 0700 "$cipher_directory" "$runtime_directory" "$mountpoint"
      exec 9>"$runtime_directory/launcher.lock"
      if ! flock -n 9; then
        show_error ${lib.escapeShellArg "The protected browser is already opening or running."}
        exit 1
      fi
      focus_launch_workspace
      # The event listener must not inherit the launcher lock. Otherwise a
      # failed password prompt can leave socat holding the lock after this
      # shell exits, permanently blocking every later attempt.
      place_protected_windows 9>&- &
      placement_pid=$!

      if [ ! -e "$cipher_directory/gocryptfs.conf" ]; then
        GDK_BACKEND=x11 zenity \
          --info \
          --title=${lib.escapeShellArg "Protect ${cfg.protectedBrowserName}"} \
          --text=${lib.escapeShellArg "Choose a password for the protected browser. You will be asked for it twice during this one-time setup. The profile can be recovered through browser sync if this password is lost."} \
          >/dev/null 2>&1 || true

        initial_password="$(${lib.getExe protectedBrowserPasswordPrompt} create)" || exit 1
        confirmation="$(${lib.getExe protectedBrowserPasswordPrompt} confirm)" || exit 1
        if [ -z "$initial_password" ] || [ "$initial_password" != "$confirmation" ]; then
          unset confirmation initial_password
          show_error ${lib.escapeShellArg "The passwords were empty or did not match. The protected profile was not initialized."}
          exit 1
        fi
        unset confirmation

        if ! printf '%s\n' "$initial_password" | gocryptfs \
          -q \
          -init \
          -passfile /dev/stdin \
          "$cipher_directory"; then
          unset initial_password
          show_error ${lib.escapeShellArg "The encrypted browser profile could not be initialized."}
          exit 1
        fi
      fi

      if ! mountpoint -q "$mountpoint"; then
        if [ -n "$initial_password" ]; then
          printf '%s\n' "$initial_password" | gocryptfs \
            -q \
            -passfile /dev/stdin \
            "$cipher_directory" \
            "$mountpoint" || mount_status=$?
        else
          gocryptfs \
            -q \
            -extpass ${lib.escapeShellArg (lib.getExe protectedBrowserPasswordPrompt)} \
            "$cipher_directory" \
            "$mountpoint" || mount_status=$?
        fi
        unset initial_password
        if [ "''${mount_status:-0}" -ne 0 ]; then
          show_error ${lib.escapeShellArg "The protected browser profile could not be unlocked or mounted. Check the password and try again; if it persists, inspect the mount service."}
          exit 1
        fi
        mounted_here=true
      fi

      ${lib.optionalString (cfg.protectedBrowserLegacyProfileDirectory != null) ''
        legacy_profile=${lib.escapeShellArg cfg.protectedBrowserLegacyProfileDirectory}
        if [ -e "$legacy_profile/Local State" ] \
          && [ -z "$(find "$mountpoint" -mindepth 1 -print -quit)" ]; then
          legacy_lock="$(readlink "$legacy_profile/SingletonLock" 2>/dev/null || true)"
          legacy_pid="''${legacy_lock##*-}"
          if [ -n "$legacy_lock" ] \
            && [ "$legacy_pid" != "$legacy_lock" ] \
            && kill -0 "$legacy_pid" 2>/dev/null; then
            show_error ${lib.escapeShellArg "Close the existing Brave window first. Its temporary profile is safe and will be migrated on the next protected launch."}
            exit 1
          fi

          cp -a --reflink=auto "$legacy_profile/." "$mountpoint/"
          rm -f \
            "$mountpoint/SingletonCookie" \
            "$mountpoint/SingletonLock" \
            "$mountpoint/SingletonSocket"
          touch "$mountpoint/.couch-profile-migrated"
        fi
      ''}

      flock -u 9
      exec 9>&-
      focus_launch_workspace

      status=0
      ${lib.getExe cfg.protectedBrowserPackage} \
        --class=ProtectedBrowser \
        --user-data-dir="$mountpoint" \
        --ozone-platform=x11 \
        --password-store=basic \
        --force-device-scale-factor=${toString cfg.browserScaleFactor} \
        --disable-background-mode \
        "$@" || status=$?
      exit "$status"
    '';
  };

  protectedBrowser = pkgs.writeShellApplication {
    name = cfg.protectedBrowserCommandName;
    runtimeInputs = [
      pkgs.hyprland
      pkgs.systemd
    ];
    text = ''
      unit=couch-protected-browser.service
      if systemctl --user --quiet is-active "$unit"; then
        hyprctl dispatch focuswindow 'class:^(ProtectedBrowser)$' >/dev/null 2>&1 || true
        exit 0
      fi

      systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
      exec systemctl --user start "$unit"
    '';
  };

  moonlightStreamStart = pkgs.writeShellApplication {
    name = "couch-moonlight-start";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.netcat-openbsd
    ];
    text = ''
      stream_hosts=(${lib.concatMapStringsSep " " lib.escapeShellArg streamReadinessHosts})

      show_status() {
        level="$1"
        message="$2"
        details="$3"
        dms="$HOME/.nix-profile/bin/dms"
        if [ -x "$dms" ]; then
          "$dms" ipc call toast "''${level}With" \
            "$message" "$details" "" "media-center" >/dev/null 2>&1 || true
        else
          hyprctl notify 1 5000 'rgb(89b4fa)' "$message — $details" \
            >/dev/null 2>&1 || true
        fi
      }

      find_ready_host() {
        local host
        for host in "''${stream_hosts[@]}"; do
          if nc -z -w 1 "$host" ${toString cfg.streamReadinessPort} \
            >/dev/null 2>&1; then
            printf '%s\n' "$host"
            return 0
          fi
        done
        return 1
      }

      ${lib.optionalString (cfg.streamHostStartCommand != null || streamReadinessHosts != []) ''
        ready_host="$(find_ready_host || true)"
      ''}

      ${lib.optionalString (cfg.streamHostStartCommand != null) ''
        if [ -z "$ready_host" ]; then
          start_target=""
          for host in "''${stream_hosts[@]}"; do
            if nc -z -w 1 "$host" ${toString cfg.streamHostControlPort} \
              >/dev/null 2>&1; then
              start_target="$host"
              break
            fi
          done
          if [ -z "$start_target" ] && [ "''${#stream_hosts[@]}" -gt 0 ]; then
            start_target="''${stream_hosts[0]}"
          fi
          export COUCH_STREAM_START_TARGET="$start_target"
          show_status info "Starting Steam" \
            "Starting the remote Steam host. A cold start can take up to ${toString cfg.streamStartupTimeout} seconds."
          ${cfg.streamHostStartCommand}
          show_status info "Steam container started" \
            "Waiting for the streaming service to become ready."
        fi
      ''}

      ${lib.optionalString (streamReadinessHosts != []) ''
        ready_host=""
        for ((attempt = 0; attempt < ${toString cfg.streamStartupTimeout}; attempt++)); do
          ready_host="$(find_ready_host || true)"
          if [ -n "$ready_host" ]; then
            break
          fi
          sleep 1
        done

        if [ -z "$ready_host" ]; then
          show_status error "Steam did not start" \
            "The streaming service was not ready after ${toString cfg.streamStartupTimeout} seconds."
          echo "stream host did not become ready" >&2
          exit 1
        fi
      ''}

      ${
        if directStreamEnabled
        then ''show_status info "Steam is ready" "Connecting Moonlight now."''
        else ''show_status info "Moonlight" "Opening the host chooser."''
      }
      exec ${lib.getExe moonlightSession}
    '';
  };

  mkMoonlightBrowserSession = name: endpointSetup: invocation: targetWorkspace: application:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.hyprland
        pkgs.jq
      ];
      text = ''
        ${lib.optionalString (
            application == cfg.browserStreamApplication && cfg.browserStreamPrepareCommand != null
          )
          cfg.browserStreamPrepareCommand}
        ${lib.getExe endpointSetup}
        ${lib.getExe displayModeSetup}
        ${invocation} &
        moonlight_pid=$!
        ${lib.optionalString (cfg.browserStreamLayoutCommand != null) ''
          (
            COUCH_KEYBOARD_LAYOUT="$(${lib.getExe activeKeyboardLayout})"
            export COUCH_KEYBOARD_LAYOUT
            export COUCH_PRESENTATION_SCALE=${toString cfg.browserPresentationScale}
            export COUCH_STREAM_APPLICATION=${
            lib.escapeShellArg (
              if application == null
              then ""
              else application
            )
          }
            ${cfg.browserStreamLayoutCommand}
          ) &
        ''}
        ${superviseMoonlightWindow targetWorkspace}
        exit "$status"
      '';
    };
  moonlightBrowserSession =
    mkMoonlightBrowserSession "moonlight-browser-session" moonlightEndpointSetup
    browserMoonlightInvocation
    2
    cfg.browserStreamApplication;
  moonlightBrowserSelectorSession =
    mkMoonlightBrowserSession "moonlight-browser-selector-session" browserSelectorEndpointSetup
    browserSelectorMoonlightInvocation
    3
    cfg.browserStreamSelectorApplication;
  directDrmStreamHostPrepare = pkgs.writeShellApplication {
    name = "moonlight-direct-drm-stream-host-prepare";
    runtimeInputs = [pkgs.netcat-openbsd];
    text = ''
      stream_hosts=(${lib.concatMapStringsSep " " lib.escapeShellArg streamReadinessHosts})

      find_ready_host() {
        local host
        for host in "''${stream_hosts[@]}"; do
          if nc -z -w 1 "$host" ${toString cfg.streamReadinessPort} \
            >/dev/null 2>&1; then
            printf '%s\n' "$host"
            return 0
          fi
        done
        return 1
      }

      ${lib.optionalString (cfg.streamHostStartCommand != null || streamReadinessHosts != []) ''
        ready_host="$(find_ready_host || true)"
      ''}

      ${lib.optionalString (cfg.streamHostStartCommand != null) ''
        if [ -z "$ready_host" ]; then
          start_target=""
          for host in "''${stream_hosts[@]}"; do
            if nc -z -w 1 "$host" ${toString cfg.streamHostControlPort} \
              >/dev/null 2>&1; then
              start_target="$host"
              break
            fi
          done
          if [ -z "$start_target" ] && [ "''${#stream_hosts[@]}" -gt 0 ]; then
            start_target="''${stream_hosts[0]}"
          fi
          export COUCH_STREAM_START_TARGET="$start_target"
          ${cfg.streamHostStartCommand}
        fi
      ''}

      ${lib.optionalString (streamReadinessHosts != []) ''
        ready_host=""
        for ((attempt = 0; attempt < ${toString cfg.streamStartupTimeout}; attempt++)); do
          ready_host="$(find_ready_host || true)"
          if [ -n "$ready_host" ]; then
            exit 0
          fi
          sleep 1
        done
        echo "stream host did not become ready" >&2
        exit 1
      ''}
    '';
  };
  mkDirectDrmSession = {
    name,
    mode,
    endpointSetup,
    invocation,
    application ? null,
    prepareCommand ? null,
    retryOnExit ? false,
  }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.systemd
      ];
      text = ''
        active_mode=${lib.escapeShellArg mode}
        persist_mode() {
          mode_tmp="$(mktemp ${lib.escapeShellArg "${modeStateFile}.XXXXXX"})"
          printf '%s\n' "$1" > "$mode_tmp"
          chmod 0644 "$mode_tmp"
          mv -f "$mode_tmp" ${lib.escapeShellArg modeStateFile}
        }
        return_mode="$(
          tr -d '[:space:]' \
            < ${lib.escapeShellArg directDrmReturnModeFile} \
            2>/dev/null \
            || true
        )"
        case "$return_mode" in
          couch${
          lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
        }${lib.optionalString cfg.enableMergedProfile " | merged"}${
          lib.optionalString (cfg.defaultSessionMode == mode) " | ${mode}"
        }) ;;
          *) return_mode=${lib.escapeShellArg cfg.defaultSessionMode} ;;
        esac

        return_to_session() {
          status="''${1:-0}"
          trap - EXIT HUP INT TERM
          current_mode="$(
            tr -d '[:space:]' \
              < ${lib.escapeShellArg modeStateFile} \
              2>/dev/null \
              || true
          )"
          current_mode="''${current_mode%%:*}"
          if [ -z "$current_mode" ]; then
            current_mode=${lib.escapeShellArg cfg.defaultSessionMode}
          fi
          # An operator may force a direct session back to couch over SSH.
          # Preserve that explicit request instead of racing it with the
          # exiting DRM wrapper's normal return mode.
          if [ "$current_mode" = "$active_mode" ] \
              && [ "$return_mode" != "$current_mode" ]; then
            persist_mode "$return_mode"
            # Keep greetd's initial session alive long enough for the path unit
            # to restart it. Otherwise greetd can race ahead to its greeter,
            # which then needs the bounded stop timeout before recovery.
            sleep 2
          fi
          exit "$status"
        }
        trap 'return_to_session 0' HUP INT TERM
        trap 'return_to_session $?' EXIT

        # These processes depend on Hyprland/XWayland and cannot operate while
        # EGLFS owns the display. Hyprland's exec-once hooks restore them when
        # the normal couch session returns.
        systemctl --user stop \
          couch-moonlight-stream.service \
          couch-moonlight-browser-stream.service \
          couch-moonlight-browser-selector.service \
          couch-protected-browser.service \
          couch-dms.service \
          couch-merged-dms.service \
          kdeconnect.service \
          waynergy.service \
          xdg-desktop-portal-gtk.service \
          >/dev/null 2>&1 || true
        # The compositor may disappear before its clients process the stop
        # request, causing an otherwise expected broken Wayland connection to
        # leave a failed-unit marker behind for the whole DRM session.
        systemctl --user reset-failed \
          couch-moonlight-stream.service \
          couch-moonlight-browser-stream.service \
          couch-moonlight-browser-selector.service \
          couch-protected-browser.service \
          couch-dms.service \
          couch-merged-dms.service \
          kdeconnect.service \
          waynergy.service \
          xdg-desktop-portal-gtk.service \
          >/dev/null 2>&1 || true

        ${lib.optionalString cfg.enableKdeConnect ''
          # Direct DRM has no compositor-owned X display. The supervised KDE
          # Connect launcher supplies an isolated Xvfb display while its
          # preload shim forwards phone input into the direct uinput bridge.
          systemctl --user restart kdeconnect.service >/dev/null 2>&1 || true
        ''}

        ${lib.optionalString (prepareCommand != null) "${prepareCommand}\n"}
        run_moonlight() {
          if ${lib.getExe endpointSetup}; then
            :
          else
            status=$?
            return "$status"
          fi
          ${lib.optionalString (
          cfg.directDrmAudioOutputByConnector != {}
        ) "${lib.getExe directDrmAudioOutputSetup}"}
          ${
          if cfg.directDrmLogToJournal
          then ''
            log_dir="$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/moonlight-direct-drm.XXXXXX")"
            log_fifo="$log_dir/output"
            pid_file="$log_dir/pid"
            mkfifo -m 600 "$log_fifo"
            (
              while IFS= read -r line || [ -n "$line" ]; do
                printf '%s\n' "$line" > /dev/tty1
                printf '%s\n' "$line"
                case "$line" in
                  *"Connection terminated:"*)
                    if read -r failed_pid < "$pid_file"; then
                      kill -TERM "$failed_pid" 2>/dev/null || true
                    fi
                    ;;
                esac
              done < "$log_fifo"
            ) | ${pkgs.systemd}/bin/systemd-cat --identifier=moonlight-direct-drm &
            logger_pid=$!
            ${invocation} \
              > "$log_fifo" 2>&1 &
          ''
          else "${invocation} &"
        }
          moonlight_pid=$!
          ${lib.optionalString cfg.directDrmLogToJournal ''
          printf '%s\n' "$moonlight_pid" > "$pid_file"
        ''}

          ${lib.optionalString (cfg.browserStreamLayoutCommand != null) ''
          (
            COUCH_KEYBOARD_LAYOUT="$(
              tr -d '[:space:]' \
                < ${lib.escapeShellArg directDrmKeyboardLayoutFile} \
                2>/dev/null \
                || true
            )"
            if [ -z "$COUCH_KEYBOARD_LAYOUT" ]; then
              configured_layouts=${lib.escapeShellArg cfg.keyboardLayouts}
              COUCH_KEYBOARD_LAYOUT="''${configured_layouts%%,*}"
            fi
            export COUCH_KEYBOARD_LAYOUT
            export COUCH_PRESENTATION_SCALE=${toString cfg.browserPresentationScale}
            export COUCH_STREAM_APPLICATION=${
            lib.escapeShellArg (
              if application == null
              then ""
              else application
            )
          }
            ${cfg.browserStreamLayoutCommand}
          ) &
        ''}

          if wait "$moonlight_pid"; then
            status=0
          else
            status=$?
          fi
          ${lib.optionalString cfg.directDrmLogToJournal ''
          wait "$logger_pid" 2>/dev/null || true
          rm -f "$log_fifo" "$pid_file"
          rmdir "$log_dir"
        ''}
        }

        ${
          if retryOnExit
          then ''
            # Persistent direct-display appliances should recover after a
            # coordinator or network outage without returning to the greeter.
            # An explicit mode change is still authoritative: its control path
            # updates the mode file before terminating Moonlight.
            while true; do
              if run_moonlight; then
                :
              else
                status=$?
              fi
              current_mode="$(
                tr -d '[:space:]' \
                  < ${lib.escapeShellArg modeStateFile} \
                  2>/dev/null \
                || true
              )"
              current_mode="''${current_mode%%:*}"
              if [ -z "$current_mode" ]; then
                current_mode=${lib.escapeShellArg cfg.defaultSessionMode}
              fi
              if [ "$current_mode" != "$active_mode" ]; then
                return_to_session "$status"
              fi
              sleep 2
            done
          ''
          else ''
            run_moonlight
            return_to_session "$status"
          ''
        }
      '';
    };
  directDrmBrowserSession = mkDirectDrmSession {
    name = "moonlight-direct-drm-browser-session";
    mode = "direct-browser";
    endpointSetup = moonlightEndpointSetup;
    invocation = directDrmBrowserMoonlightInvocation;
    application = cfg.browserStreamApplication;
    prepareCommand = cfg.browserStreamPrepareCommand;
    retryOnExit = persistentDirectDrmBrowserDefault;
  };
  directDrmBrowserSelectorSession = mkDirectDrmSession {
    name = "moonlight-direct-drm-browser-selector-session";
    mode = "direct-private";
    endpointSetup = browserSelectorEndpointSetup;
    invocation = directDrmBrowserSelectorMoonlightInvocation;
    application = cfg.browserStreamSelectorApplication;
  };
  directDrmStreamSession = mkDirectDrmSession {
    name = "moonlight-direct-drm-stream-session";
    mode = "direct-stream";
    endpointSetup = moonlightEndpointSetup;
    invocation = directDrmMoonlightInvocation;
    prepareCommand = lib.getExe directDrmStreamHostPrepare;
  };

  couchStreamControl = pkgs.writeShellApplication {
    name = "couch-stream-control";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      case "''${1:-}" in
        start)
          systemctl --user start couch-moonlight-stream.service
          hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
          ;;
        remote-browser)
          systemctl --user start couch-moonlight-browser-stream.service
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          ;;
        private-browser)
          systemctl --user start couch-moonlight-browser-selector.service
          hyprctl dispatch workspace 3 >/dev/null 2>&1 || true
          ;;
        browser)
          ${
        if browserStreamEnabled
        then ''
          systemctl --user start couch-moonlight-browser-stream.service
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        ''
        else if cfg.enableLocalBrowser
        then ''
          ${lib.getExe mergedUiControl} browser
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          if ! pgrep -u "$USER" -f -- ${lib.escapeShellArg cfg.browserProfileDirectory} \
            >/dev/null 2>&1; then
            ${lib.getExe couchBrowser} >/dev/null 2>&1 &
          fi
        ''
        else ''
          echo "No local or remote browser is configured" >&2
          exit 1
        ''
      }
          ;;
        *)
          echo "usage: couch-stream-control {start|remote-browser|private-browser|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  closeActiveWindow = pkgs.writeShellApplication {
    name = "couch-close-active-window";
    runtimeInputs = [
      pkgs.gawk
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      active_pid="$(hyprctl -j activewindow 2>/dev/null | jq -r '.pid // 0')"
      managed_unit=""

      if [[ "$active_pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$active_pid/cgroup" ]; then
        cgroup="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$active_pid/cgroup")"
        case "$cgroup" in
          */couch-moonlight-stream.service)
            managed_unit=couch-moonlight-stream.service
            ;;
          */couch-moonlight-browser-stream.service)
            managed_unit=couch-moonlight-browser-stream.service
            ;;
          */couch-moonlight-browser-selector.service)
            managed_unit=couch-moonlight-browser-selector.service
            ;;
        esac
      fi

      if [ -n "$managed_unit" ]; then
        # A stalled decoder can leave Moonlight's GUI event loop unable to
        # honor Hyprland's close request. Stop the owning cgroup instead; the
        # unit applies a bounded graceful timeout before killing leftovers.
        exec systemctl --user --no-block stop "$managed_unit"
      fi

      exec hyprctl dispatch killactive
    '';
  };

  couchControlHelp = pkgs.writeShellApplication {
    name = "couch-control-help";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi

      exec "$dms" ipc call keybinds toggle xps-media-center
    '';
  };

  controllerPython = pkgs.python3.withPackages (pythonPackages: [pythonPackages.evdev]);
  controllerDaemonSource = pkgs.writeText "couch-controller.py" ''
    import select
    import subprocess
    import time

    from evdev import InputDevice, ecodes, list_devices


    DEVICE_NAME = ${builtins.toJSON cfg.controllerDeviceName}
    HOLD_SECONDS = ${toString cfg.controllerHoldSeconds}
    ACTIONS = {
        "start": {ecodes.BTN_MODE, ecodes.BTN_EAST},
        ${lib.optionalString browserStreamEnabled ''
      "remote_browser": {ecodes.BTN_MODE, ecodes.BTN_NORTH},
    ''}
        ${lib.optionalString (browserStreamEnabled || cfg.enableLocalBrowser) ''
      "browser": {ecodes.BTN_THUMBL, ecodes.BTN_THUMBR},
    ''}
        ${lib.optionalString (cfg.enableDms || cfg.enableMergedProfile) ''
      "help": {ecodes.BTN_SELECT, ecodes.BTN_SOUTH},
    ''}
        ${lib.optionalString cfg.enableMirrorToggle ''
      "mirror": {ecodes.BTN_SELECT, ecodes.BTN_START},
    ''}
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
      "layout": {ecodes.BTN_SELECT, ecodes.BTN_NORTH},
    ''}
        ${lib.optionalString cfg.enableAudioOutputCycle ''
      "audio": {ecodes.BTN_SELECT, ecodes.BTN_WEST},
    ''}
    }
    COMMANDS = {
        "start": [${builtins.toJSON (lib.getExe couchStreamControl)}, "start"],
        ${lib.optionalString browserStreamEnabled ''
      "remote_browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "remote-browser"],
    ''}
        ${lib.optionalString (browserStreamEnabled || cfg.enableLocalBrowser) ''
      "browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "browser"],
    ''}
        ${lib.optionalString (cfg.enableDms || cfg.enableMergedProfile) ''
      "help": [${builtins.toJSON (lib.getExe couchControlHelp)}],
    ''}
        ${lib.optionalString cfg.enableMirrorToggle ''
      "mirror": [${builtins.toJSON (lib.getExe displayMirrorToggle)}, "toggle"],
    ''}
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
      "layout": [${builtins.toJSON (lib.getExe displayLayoutControl)}, "cycle"],
    ''}
        ${lib.optionalString cfg.enableAudioOutputCycle ''
      "audio": [${builtins.toJSON (lib.getExe audioOutputControl)}, "cycle"],
    ''}
    }


    def find_controller():
        for path in list_devices():
            device = InputDevice(path)
            if device.name == DEVICE_NAME and ecodes.EV_KEY in device.capabilities():
                return device
            device.close()
        return None


    def run_action(action):
        subprocess.Popen(
            COMMANDS[action],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


    while True:
        controller = find_controller()
        if controller is None:
            time.sleep(2)
            continue

        pressed = set()
        started_at = {}
        triggered = set()

        try:
            while True:
                readable, _, _ = select.select([controller.fd], [], [], 0.1)
                if readable:
                    for event in controller.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.value:
                            pressed.add(event.code)
                        else:
                            pressed.discard(event.code)

                now = time.monotonic()
                for action, buttons in ACTIONS.items():
                    if buttons.issubset(pressed):
                        started_at.setdefault(action, now)
                        if action not in triggered and now - started_at[action] >= HOLD_SECONDS:
                            run_action(action)
                            triggered.add(action)
                    else:
                        started_at.pop(action, None)
                        triggered.discard(action)
        except (OSError, ValueError):
            controller.close()
            time.sleep(1)
  '';

  controllerDaemon = pkgs.writeShellApplication {
    name = "couch-controller";
    text = ''
      exec ${controllerPython}/bin/python ${controllerDaemonSource}
    '';
  };

  directModeInputDaemonSource = pkgs.writeText "nixbox-direct-input.py" ''
    import os
    import select
    import socket
    import subprocess
    import time

    from evdev import InputDevice, UInput, ecodes, list_devices


    MODE_FILE = ${builtins.toJSON modeStateFile}
    CONTROLLER_NAME = ${builtins.toJSON cfg.controllerDeviceName}
    CONTROLLER_HOLD_SECONDS = ${toString cfg.controllerHoldSeconds}
    DEVICE_REFRESH_SECONDS = 1.0
    INACTIVE_MODE_SLEEP_SECONDS = 0.5
    KDECONNECT_DIRECT_INPUT = ${
      if kdeConnectDirectInputEnabled
      then "True"
      else "False"
    }
    KDECONNECT_SOCKET_PATH = os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"),
        "kdeconnect-hypr-pointer.sock",
    )
    IGNORED_KEYBOARD_NAMES = ("kde connect", "moonlight", "uinput", "virtual", "waynergy")
    KDECONNECT_BUTTONS = {
        1: ecodes.BTN_LEFT,
        2: ecodes.BTN_MIDDLE,
        3: ecodes.BTN_RIGHT,
        8: ecodes.BTN_SIDE,
        9: ecodes.BTN_EXTRA,
    }
    KDECONNECT_SCROLL = {
        4: (ecodes.REL_WHEEL, 1),
        5: (ecodes.REL_WHEEL, -1),
        6: (ecodes.REL_HWHEEL, -1),
        7: (ecodes.REL_HWHEEL, 1),
    }
    KDECONNECT_UINPUT_CAPABILITIES = {
        ecodes.EV_KEY: list(range(1, ecodes.KEY_MAX + 1)),
        ecodes.EV_REL: [
            ecodes.REL_X,
            ecodes.REL_Y,
            ecodes.REL_WHEEL,
            ecodes.REL_HWHEEL,
        ],
    }
    COMMANDS = {
        ${lib.optionalString directDrmBrowserEnabled ''
      "direct-browser": [${builtins.toJSON (lib.getExe sessionMode)}, "direct-browser"],
    ''}
        ${lib.optionalString directDrmStreamEnabled ''
      "direct-stream": [${builtins.toJSON (lib.getExe sessionMode)}, "direct-stream"],
    ''}
        ${lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled) ''
      "direct-private": [${builtins.toJSON (lib.getExe sessionMode)}, "direct-private"],
    ''}
    }


    def current_mode():
        try:
            with open(MODE_FILE, encoding="utf-8") as mode_file:
                return mode_file.read().strip().split(":", 1)[0]
        except OSError:
            return ""


    def open_kdeconnect_input():
        if not KDECONNECT_DIRECT_INPUT:
            return None, None
        try:
            os.unlink(KDECONNECT_SOCKET_PATH)
        except FileNotFoundError:
            pass
        input_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            input_socket.bind(KDECONNECT_SOCKET_PATH)
            os.chmod(KDECONNECT_SOCKET_PATH, 0o600)
            input_socket.setblocking(False)
            virtual_input = UInput(
                KDECONNECT_UINPUT_CAPABILITIES,
                name="Nixbox KDE Connect Direct Input",
            )
        except Exception:
            input_socket.close()
            try:
                os.unlink(KDECONNECT_SOCKET_PATH)
            except FileNotFoundError:
                pass
            raise
        print("Listening for direct KDE Connect input", flush=True)
        return input_socket, virtual_input


    def close_kdeconnect_input(input_socket, virtual_input):
        if input_socket is None and virtual_input is None:
            return
        if input_socket is not None:
            input_socket.close()
        if virtual_input is not None:
            virtual_input.close()
        try:
            os.unlink(KDECONNECT_SOCKET_PATH)
        except FileNotFoundError:
            pass


    def inject_kdeconnect_message(virtual_input, message):
        try:
            kind, first, second = message.decode().split()
            first = int(first)
            second = int(second)
        except (UnicodeDecodeError, ValueError):
            return

        if kind == "K":
            # Xorg's standard evdev keycodes are Linux input codes plus eight.
            code = first - 8
            if 0 < code <= ecodes.KEY_MAX:
                virtual_input.write(ecodes.EV_KEY, code, int(bool(second)))
                virtual_input.syn()
        elif kind == "B":
            if first in KDECONNECT_SCROLL:
                if second:
                    code, value = KDECONNECT_SCROLL[first]
                    virtual_input.write(ecodes.EV_REL, code, value)
                    virtual_input.syn()
            elif first in KDECONNECT_BUTTONS:
                virtual_input.write(
                    ecodes.EV_KEY,
                    KDECONNECT_BUTTONS[first],
                    int(bool(second)),
                )
                virtual_input.syn()
        elif kind == "M" and (first or second):
            if first:
                virtual_input.write(ecodes.EV_REL, ecodes.REL_X, first)
            if second:
                virtual_input.write(ecodes.EV_REL, ecodes.REL_Y, second)
            virtual_input.syn()


    def close_devices(devices):
        for state in devices.values():
            state["device"].close()
        devices.clear()


    def classify_device(device):
        capabilities = device.capabilities()
        keys = set(capabilities.get(ecodes.EV_KEY, []))

        if device.name == CONTROLLER_NAME and ecodes.BTN_MODE in keys:
            return "controller"

        name = device.name.lower()
        if any(fragment in name for fragment in IGNORED_KEYBOARD_NAMES):
            return None
        has_meta = ecodes.KEY_LEFTMETA in keys or ecodes.KEY_RIGHTMETA in keys
        if has_meta and ecodes.KEY_R in keys and ecodes.KEY_M in keys:
            return "keyboard"
        return None


    def refresh_devices(devices):
        available_paths = set(list_devices())
        for path in list(devices):
            if path not in available_paths:
                devices.pop(path)["device"].close()

        for path in sorted(available_paths - set(devices)):
            try:
                device = InputDevice(path)
                role = classify_device(device)
                if role is None:
                    device.close()
                    continue
                devices[path] = {
                    "device": device,
                    "role": role,
                    "pressed": set(),
                    "hat_up": False,
                    "candidate": None,
                    "candidate_since": None,
                    "latched": False,
                }
                print(f"Listening to {role} input from {device.name}", flush=True)
            except (OSError, PermissionError):
                continue


    def keyboard_action(state):
        pressed = state["pressed"]
        meta = ecodes.KEY_LEFTMETA in pressed or ecodes.KEY_RIGHTMETA in pressed
        shift = ecodes.KEY_LEFTSHIFT in pressed or ecodes.KEY_RIGHTSHIFT in pressed
        if not meta:
            return None
        ${lib.optionalString (
      directDrmBrowserEnabled && browserSelectorEnabled
    ) "if shift and ecodes.KEY_R in pressed:\n        return \"direct-private\"\n"}
        ${lib.optionalString directDrmBrowserEnabled "if not shift and ecodes.KEY_R in pressed:\n        return \"direct-browser\"\n"}
        ${lib.optionalString directDrmStreamEnabled "if not shift and ecodes.KEY_M in pressed:\n        return \"direct-stream\"\n"}
        return None


    def controller_action(state):
        pressed = state["pressed"]
        ${
      lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled)
      "if (\n        state[\"hat_up\"]\n        and ecodes.BTN_START in pressed\n        and ecodes.BTN_TR in pressed\n    ):\n        return \"direct-private\"\n"
    }
        ${lib.optionalString directDrmBrowserEnabled "if ecodes.BTN_MODE in pressed and ecodes.BTN_NORTH in pressed:\n        return \"direct-browser\"\n"}
        ${lib.optionalString directDrmStreamEnabled "if ecodes.BTN_MODE in pressed and ecodes.BTN_EAST in pressed:\n        return \"direct-stream\"\n"}
        return None


    def requested_action(state):
        if state["role"] == "keyboard":
            return keyboard_action(state)
        return controller_action(state)


    def run_action(action):
        print(f"Requesting {action}", flush=True)
        subprocess.Popen(
            COMMANDS[action],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


    devices = {}
    next_refresh = 0.0
    kdeconnect_socket = None
    kdeconnect_uinput = None

    while True:
        if not current_mode().startswith("direct-"):
            close_devices(devices)
            close_kdeconnect_input(kdeconnect_socket, kdeconnect_uinput)
            kdeconnect_socket = None
            kdeconnect_uinput = None
            next_refresh = 0.0
            time.sleep(INACTIVE_MODE_SLEEP_SECONDS)
            continue

        if KDECONNECT_DIRECT_INPUT and kdeconnect_socket is None:
            try:
                kdeconnect_socket, kdeconnect_uinput = open_kdeconnect_input()
            except (OSError, PermissionError) as error:
                print(f"Waiting for KDE Connect direct input: {error}", flush=True)
                time.sleep(INACTIVE_MODE_SLEEP_SECONDS)
                continue

        now = time.monotonic()
        if now >= next_refresh:
            refresh_devices(devices)
            next_refresh = now + DEVICE_REFRESH_SECONDS

        readers = [state["device"].fd for state in devices.values()]
        if kdeconnect_socket is not None:
            readers.append(kdeconnect_socket)
        if not readers:
            time.sleep(INACTIVE_MODE_SLEEP_SECONDS)
            continue

        try:
            readable, _, _ = select.select(
                readers,
                [],
                [],
                0.1,
            )
        except (OSError, ValueError):
            close_devices(devices)
            close_kdeconnect_input(kdeconnect_socket, kdeconnect_uinput)
            kdeconnect_socket = None
            kdeconnect_uinput = None
            next_refresh = 0.0
            continue

        if kdeconnect_socket is not None and kdeconnect_socket in readable:
            while True:
                try:
                    message = kdeconnect_socket.recv(96)
                except BlockingIOError:
                    break
                try:
                    inject_kdeconnect_message(kdeconnect_uinput, message)
                except OSError:
                    close_kdeconnect_input(kdeconnect_socket, kdeconnect_uinput)
                    kdeconnect_socket = None
                    kdeconnect_uinput = None
                    break

        readable_fds = {
            item if isinstance(item, int) else item.fileno()
            for item in readable
        }
        for path, state in list(devices.items()):
            if state["device"].fd not in readable_fds:
                continue
            try:
                for event in state["device"].read():
                    if event.type == ecodes.EV_KEY:
                        if event.value:
                            state["pressed"].add(event.code)
                        else:
                            state["pressed"].discard(event.code)
                    elif (
                        state["role"] == "controller"
                        and event.type == ecodes.EV_ABS
                        and event.code == ecodes.ABS_HAT0Y
                    ):
                        state["hat_up"] = event.value < 0
            except (OSError, ValueError):
                devices.pop(path)["device"].close()
                continue

        now = time.monotonic()
        for state in devices.values():
            action = requested_action(state)
            if action is None:
                state["candidate"] = None
                state["candidate_since"] = None
                state["latched"] = False
                continue
            if state["latched"]:
                continue
            if state["candidate"] != action:
                state["candidate"] = action
                state["candidate_since"] = now
                continue
            hold_seconds = 0.0 if state["role"] == "keyboard" else CONTROLLER_HOLD_SECONDS
            if now - state["candidate_since"] >= hold_seconds:
                run_action(action)
                state["latched"] = True
  '';

  directModeInputDaemon = pkgs.writeShellApplication {
    name = "nixbox-direct-input";
    text = ''
      exec ${controllerPython}/bin/python ${directModeInputDaemonSource}
    '';
  };

  kdeConnectPointerShimSource = pkgs.writeText "kdeconnect-hypr-pointer-shim.c" ''
    #define _GNU_SOURCE

    #include <dlfcn.h>
    #include <errno.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <time.h>
    #include <sys/socket.h>
    #include <sys/un.h>
    #include <unistd.h>
    #include <X11/Xlib.h>
    #include <X11/extensions/XTest.h>
    #include <xcb/xcb.h>

    typedef xcb_void_cookie_t (*warp_pointer_fn)(
        xcb_connection_t *, xcb_window_t, xcb_window_t,
        int16_t, int16_t, uint16_t, uint16_t, int16_t, int16_t);
    typedef Bool (*fake_button_fn)(Display *, unsigned int, Bool, unsigned long);
    typedef Bool (*fake_key_fn)(Display *, unsigned int, Bool, unsigned long);

    static void send_motion(const char *kind, int x, int y)
    {
        const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
        struct sockaddr_un address = { .sun_family = AF_UNIX };
        char message[96];
        int fd;
        int message_length;

        if (!runtime_dir || !*runtime_dir)
            return;
        if (snprintf(address.sun_path, sizeof(address.sun_path),
                     "%s/kdeconnect-hypr-pointer.sock", runtime_dir)
            >= (int)sizeof(address.sun_path))
            return;

        message_length = snprintf(message, sizeof(message), "%s %d %d", kind, x, y);
        if (message_length <= 0 || message_length >= (int)sizeof(message))
            return;

        fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (fd < 0)
            return;
        (void)sendto(fd, message, (size_t)message_length, MSG_DONTWAIT,
                     (const struct sockaddr *)&address, sizeof(address));
        close(fd);
    }

    static long scroll_interval_ms(void)
    {
        static long interval = -1;
        char *end = NULL;
        const char *configured;
        long parsed;

        if (interval >= 0)
            return interval;
        configured = getenv("KDECONNECT_SCROLL_INTERVAL_MS");
        if (!configured || !*configured) {
            interval = 0;
            return interval;
        }
        parsed = strtol(configured, &end, 10);
        interval = end != configured && *end == '\0' && parsed > 0 ? parsed : 0;
        return interval;
    }

    Bool XTestFakeButtonEvent(
        Display *display,
        unsigned int button,
        Bool is_press,
        unsigned long delay)
    {
        static fake_button_fn real_fake_button;
        static long long last_scroll_ns;
        static Bool suppress_release[8];
        struct timespec now;
        long interval;
        long long now_ns;

        if (!real_fake_button)
            real_fake_button =
                (fake_button_fn)dlsym(RTLD_NEXT, "XTestFakeButtonEvent");
        if (!real_fake_button)
            return False;

        interval = scroll_interval_ms();
        if (button >= 4 && button <= 7 && interval > 0) {
            if (!is_press && suppress_release[button]) {
                suppress_release[button] = False;
                return True;
            }
            if (is_press && clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
                now_ns = (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
                if (last_scroll_ns != 0
                    && now_ns - last_scroll_ns < interval * 1000000LL) {
                    suppress_release[button] = True;
                    return True;
                }
                last_scroll_ns = now_ns;
            }
        }

        send_motion("B", (int)button, is_press ? 1 : 0);
        return real_fake_button(display, button, is_press, delay);
    }

    Bool XTestFakeKeyEvent(
        Display *display,
        unsigned int keycode,
        Bool is_press,
        unsigned long delay)
    {
        static fake_key_fn real_fake_key;

        if (!real_fake_key)
            real_fake_key = (fake_key_fn)dlsym(RTLD_NEXT, "XTestFakeKeyEvent");
        if (!real_fake_key)
            return False;

        send_motion("K", (int)keycode, is_press ? 1 : 0);
        return real_fake_key(display, keycode, is_press, delay);
    }

    xcb_void_cookie_t xcb_warp_pointer(
        xcb_connection_t *connection,
        xcb_window_t source_window,
        xcb_window_t destination_window,
        int16_t source_x,
        int16_t source_y,
        uint16_t source_width,
        uint16_t source_height,
        int16_t destination_x,
        int16_t destination_y)
    {
        static warp_pointer_fn real_warp_pointer;
        xcb_query_pointer_cookie_t query_cookie;
        xcb_query_pointer_reply_t *query_reply = NULL;
        xcb_void_cookie_t result = { 0 };

        if (!real_warp_pointer)
            real_warp_pointer = (warp_pointer_fn)dlsym(RTLD_NEXT, "xcb_warp_pointer");

        if (destination_window != XCB_NONE) {
            query_cookie = xcb_query_pointer(connection, destination_window);
            query_reply = xcb_query_pointer_reply(connection, query_cookie, NULL);
        }
        if (query_reply) {
            send_motion("M",
                        (int)destination_x - (int)query_reply->root_x,
                        (int)destination_y - (int)query_reply->root_y);
            free(query_reply);
        } else {
            send_motion("A", destination_x, destination_y);
        }

        if (real_warp_pointer) {
            result = real_warp_pointer(
                connection,
                source_window,
                destination_window,
                source_x,
                source_y,
                source_width,
                source_height,
                destination_x,
                destination_y);
        }
        return result;
    }
  '';

  kdeConnectPointerShim =
    pkgs.runCommandCC "kdeconnect-hypr-pointer-shim"
    {
      nativeBuildInputs = [pkgs.pkg-config];
      buildInputs = [
        pkgs.libx11
        pkgs.libxcb
        pkgs.libxi
        pkgs.libxtst
      ];
    }
    ''
      install -d "$out/lib"
      "$CC" \
        -shared \
        -fPIC \
        -Wall \
        -Wextra \
        -Werror \
        $(${pkgs.pkg-config}/bin/pkg-config --cflags x11 xcb xi xtst) \
        -o "$out/lib/libkdeconnect-hypr-pointer-shim.so" \
        ${kdeConnectPointerShimSource} \
        $(${pkgs.pkg-config}/bin/pkg-config --libs x11 xcb xi xtst) \
        -ldl
    '';

  kdeConnectSessionLauncher = pkgs.writeShellApplication {
    name = "nixbox-kdeconnect-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.xorg-server
    ];
    text = ''
      mode="$(
        tr -d '[:space:]' \
          < ${lib.escapeShellArg modeStateFile} \
          2>/dev/null \
          || true
      )"
      case "''${mode%%:*}" in
        direct-*) ;;
        *)
          export DISPLAY=:0
          exec ${kdeConnectExecutable} --replace
          ;;
      esac

      display_file="$(mktemp -p "''${XDG_RUNTIME_DIR:-/tmp}" kdeconnect-xvfb.XXXXXX)"
      xvfb_pid=
      kdeconnect_pid=

      cleanup() {
        trap - EXIT INT TERM
        if [ -n "$kdeconnect_pid" ]; then
          kill "$kdeconnect_pid" >/dev/null 2>&1 || true
        fi
        if [ -n "$xvfb_pid" ]; then
          kill "$xvfb_pid" >/dev/null 2>&1 || true
        fi
        rm -f "$display_file"
      }
      terminate() {
        exit 0
      }
      trap cleanup EXIT
      trap terminate INT TERM

      ${lib.getExe' pkgs.xorg-server "Xvfb"} \
        -displayfd 3 \
        -nolisten tcp \
        -noreset \
        -screen 0 2560x1440x24 \
        3>"$display_file" &
      xvfb_pid=$!

      for _attempt in $(seq 1 50); do
        if [ -s "$display_file" ]; then
          break
        fi
        if ! kill -0 "$xvfb_pid" >/dev/null 2>&1; then
          echo "KDE Connect Xvfb exited before becoming ready" >&2
          exit 1
        fi
        sleep 0.1
      done
      if [ ! -s "$display_file" ]; then
        echo "KDE Connect Xvfb did not become ready" >&2
        exit 1
      fi

      display_number="$(tr -d '[:space:]' < "$display_file")"
      export DISPLAY=":$display_number"
      ${kdeConnectExecutable} --replace &
      kdeconnect_pid=$!
      wait "$kdeconnect_pid"
    '';
  };

  pointerSyncSource = pkgs.writeText "couch-xwayland-pointer-bridge.py" ''
    import json
    import os
    import re
    import socket
    import subprocess
    import time


    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    signature = os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
    hypr_socket = os.path.join(runtime_dir, "hypr", signature, ".socket.sock")
    kdeconnect_socket_path = os.path.join(
        runtime_dir, "kdeconnect-hypr-pointer.sock"
    )
    xrandr_output = re.compile(
        r"^(\S+) connected(?: primary)? (\d+)x(\d+)\+(-?\d+)\+(-?\d+)"
    )
    def hypr_request(command):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.25)
                client.connect(hypr_socket)
                client.sendall(command.encode())
                response = bytearray()
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    response.extend(chunk)
                return response.decode()
        except (OSError, UnicodeDecodeError):
            return ""


    def monitor_mapping():
        try:
            xrandr = subprocess.run(
                [${builtins.toJSON (lib.getExe pkgs.xrandr)}, "--query"],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=2,
            ).stdout
            hypr = json.loads(hypr_request("j/monitors all") or "[]")
        except (json.JSONDecodeError, OSError, subprocess.SubprocessError):
            return []

        x_outputs = {}
        for line in xrandr.splitlines():
            match = xrandr_output.match(line)
            if match:
                name, width, height, x, y = match.groups()
                x_outputs[name] = tuple(map(int, (x, y, width, height)))

        mapping = []
        for monitor in hypr:
            source = x_outputs.get(monitor.get("name"))
            scale = float(monitor.get("scale") or 1)
            if source is None or scale <= 0:
                continue
            mapping.append(
                (
                    source,
                    (
                        int(monitor.get("x", 0)),
                        int(monitor.get("y", 0)),
                        round(int(monitor.get("width", 0)) / scale),
                        round(int(monitor.get("height", 0)) / scale),
                    ),
                )
            )
        return mapping


    def translate(x, y, mapping):
        for (source_x, source_y, source_width, source_height), (
            target_x,
            target_y,
            target_width,
            target_height,
        ) in mapping:
            if (
                source_width > 0
                and source_height > 0
                and source_x <= x < source_x + source_width
                and source_y <= y < source_y + source_height
            ):
                local_x = (x - source_x) / source_width
                local_y = (y - source_y) / source_height
                return (
                    round(target_x + local_x * target_width),
                    round(target_y + local_y * target_height),
                )
        return None


    try:
        os.unlink(kdeconnect_socket_path)
    except FileNotFoundError:
        pass
    kdeconnect_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    kdeconnect_socket.bind(kdeconnect_socket_path)
    os.chmod(kdeconnect_socket_path, 0o600)
    kdeconnect_socket.setblocking(False)
    mapping = []
    mapping_updated_at = 0.0

    while True:
        now = time.monotonic()
        if now - mapping_updated_at >= 2:
            mapping = monitor_mapping()
            mapping_updated_at = now

        while True:
            try:
                message = kdeconnect_socket.recv(96).decode().split()
            except BlockingIOError:
                break
            except (OSError, UnicodeDecodeError):
                continue

            try:
                kind, first, second = message
                first = float(first)
                second = float(second)
            except (ValueError, TypeError):
                continue

            if kind == "M":
                try:
                    current = json.loads(hypr_request("j/cursorpos") or "{}")
                    target = (
                        round(float(current["x"]) + first),
                        round(float(current["y"]) + second),
                    )
                except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                    continue
            elif kind == "A":
                target = translate(first, second, mapping)
                if target is None:
                    continue
            else:
                continue
            hypr_request(f"dispatch movecursor {target[0]} {target[1]}")

        time.sleep(1 / 60)
  '';

  pointerSync = kdeConnectHyprlandInput;

  kdeConnectDbusServiceOverride = pkgs.writeTextFile {
    name = "kdeconnect-dbus-systemd-service";
    destination = "/share/dbus-1/services/org.kde.kdeconnect.service";
    text = ''
      [D-BUS Service]
      Name=org.kde.kdeconnect
      Exec=${pkgs.systemd}/bin/systemctl --user start kdeconnect.service
      SystemdService=kdeconnect.service
    '';
  };

  softwareMirror = pkgs.writeShellApplication {
    name = "couch-software-mirror";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
      pkgs.wl-mirror
    ];
    text = ''
      target="$1"
      source="$2"

      while true; do
        monitors="$(hyprctl -j monitors 2>/dev/null || true)"
        if jq -e --arg target "$target" --arg source "$source" \
          'any(.[]; .name == $target) and any(.[]; .name == $source)' \
          <<<"$monitors" >/dev/null 2>&1; then
          wl-mirror \
            --fullscreen-output "$target" \
            --scaling fit \
            --title "Couch mirror $source" \
            "$source" || true
        fi
        sleep 2
      done
    '';
  };

  audioOutputControl = pkgs.writeShellApplication {
    name = "couch-audio-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.hyprland
      pkgs.jq
      pkgs.pipewire
      pkgs.pulseaudio
      pkgs.systemd
      pkgs.wireplumber
    ];
    text = ''
      connector_audio_outputs=${lib.escapeShellArg (builtins.toJSON cfg.directDrmAudioOutputByConnector)}

      request_recovery() {
        systemctl --user --no-block start couch-audio-health-recovery.service \
          >/dev/null 2>&1 || true
      }

      load_graph() {
        if ! graph="$(timeout --kill-after=1 4 pw-dump)"; then
          echo "audio graph is unresponsive; requested recovery" >&2
          request_recovery
          return 1
        fi
      }
      load_graph

      get_sinks() {
        jq -c '
          [
            .[]
            | select(
                .type == "PipeWire:Interface:Node"
                and (.info.props["media.class"] // "") == "Audio/Sink"
              )
            | {
                id,
                description: (.info.props["node.description"] // .info.props["node.nick"] // .info.props["node.name"]),
                priority: (.info.props["priority.session"] // 0),
                api: (.info.props["device.api"] // ""),
                name: (.info.props["node.name"] // "")
              }
          ]
          | sort_by([-.priority, .description])
        ' <<<"$graph"
      }

      sinks="$(get_sinks)"
      if [ "$(jq 'length' <<<"$sinks")" -eq 0 ]; then
        echo "no audio outputs are available" >&2
        exit 1
      fi

      current_id="$(
        timeout --kill-after=1 4 wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
          | sed -n 's/^id \([0-9][0-9]*\),.*/\1/p' \
          | head -n1 \
          || true
      )"
      configured_name="$(
        jq -r '
          [
            .[]
            | select(
                .type == "PipeWire:Interface:Metadata"
                and (.props["metadata.name"] // "") == "default"
              )
            | .metadata[]?
            | select(.key == "default.configured.audio.sink")
            | .value.name // ""
          ][0] // ""
        ' <<<"$graph"
      )"

      set_default() {
        target_id="$1"
        target_name="$(
          jq -r --argjson id "$target_id" \
            '.[] | select(.id == $id) | .name' <<<"$sinks"
        )"
        if [ -z "$target_name" ]; then
          echo "selected audio output is no longer available" >&2
          return 1
        fi
        if ! timeout --kill-after=1 4 wpctl set-default "$target_id"; then
          echo "failed to select audio output; requested recovery" >&2
          request_recovery
          return 1
        fi

        # PipeWire-Pulse clients can keep their existing stream attached to a
        # disappearing Bluetooth or HDMI route even after WirePlumber changes
        # the default. Move each live stream in place so Moonlight keeps its
        # connection and server-side session while the output changes.
        if ! sink_inputs="$(timeout --kill-after=1 4 pactl list short sink-inputs)"; then
          echo "audio streams are unresponsive; requested recovery" >&2
          request_recovery
          return 1
        fi
        while read -r input_id _; do
          if [ -n "$input_id" ]; then
            timeout --kill-after=1 4 \
              pactl move-sink-input "$input_id" "$target_name" \
              >/dev/null 2>&1 || true
          fi
        done <<<"$sink_inputs"

        # SDL can retain the timing state of the previous HDMI sink after a
        # successful PipeWire-Pulse move into a Bluetooth latency domain. Ask
        # patched Moonlight clients to recreate only their audio renderer; the
        # video connection and remote application session remain untouched.
        audio_reopen_marker="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/moonlight-audio-reopen"
        printf '%s\n' "$(date +%s%N)" > "$audio_reopen_marker"
      }

      layout_target() {
        case "$1" in
          all | dual-tvs | living-bedroom) printf '%s\n' "Both TVs" ;;
          living | living-aux | primary-aux | solo-primary) printf '%s\n' "Primary TV" ;;
          bedroom | bedroom-aux | secondary-aux | solo-secondary) printf '%s\n' "Secondary TV" ;;
          aux | solo-aux | solo-tertiary) printf '%s\n' "Auxiliary display" ;;
          *) printf '%s\n' "" ;;
        esac
      }

      single_connector_target_id() {
        if [ "$(jq 'length' <<<"$connector_audio_outputs")" -eq 0 ]; then
          return
        fi

        if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
          for socket in \
            "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/hypr/*/.socket.sock; do
            [ -S "$socket" ] || continue
            HYPRLAND_INSTANCE_SIGNATURE="''${socket%/.socket.sock}"
            HYPRLAND_INSTANCE_SIGNATURE="''${HYPRLAND_INSTANCE_SIGNATURE##*/}"
            export HYPRLAND_INSTANCE_SIGNATURE
            break
          done
        fi
        if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
          return
        fi
        if ! monitors="$(
          timeout --kill-after=1 4 hyprctl -j monitors all 2>/dev/null
        )"; then
          return
        fi
        connector="$(
          jq -r '
            [
              .[]
              | select(
                  .disabled == false
                  and (.name | test("^(eDP|LVDS)-") | not)
                )
              | .name
            ]
            | if length == 1 then .[0] else "" end
          ' <<<"$monitors"
        )"
        if [ -z "$connector" ]; then
          return
        fi

        connector_target="$(
          jq -r --arg connector "$connector" \
            '.[$connector] // ""' <<<"$connector_audio_outputs"
        )"
        if [ -z "$connector_target" ]; then
          return
        fi

        jq -r --arg target "$connector_target" '
          [
            .[]
            | select(.name == $target or .description == $target)
          ][0].id // ""
        ' <<<"$sinks"
      }

      select_layout_fallback() {
        layout="''${1:-}"
        if [ -z "$layout" ]; then
          layout="$(tr -d '[:space:]' < ${lib.escapeShellArg displayLayoutStateFile} 2>/dev/null || true)"
        fi
        # A semantic layout can fall back to the only physically connected TV.
        # Prefer that connector's known audio path so, for example, a bedroom
        # layout using DP-3 cannot retain the disconnected Secondary TV PCM.
        target_id="$(single_connector_target_id)"
        if [ -z "$target_id" ]; then
          target="$(layout_target "$layout")"
          target_id="$(
            jq -r --arg target "$target" \
              '[.[] | select(.description == $target)][0].id // ""' <<<"$sinks"
          )"
        fi
        if [ -z "$target_id" ]; then
          # Adaptive or unavailable-role fallback: select the highest-priority
          # non-Bluetooth sink rather than retaining a vanished endpoint.
          target_id="$(
            jq -r '
              [
                .[]
                | select(
                    .api != "bluez5"
                    and (.name | startswith("bluez_") | not)
                  )
              ][0].id // ""
            ' <<<"$sinks"
          )"
        fi
        if [ -z "$target_id" ]; then
          echo "no local audio fallback is available" >&2
          return 1
        fi
        set_default "$target_id"
      }

      follow_layout() {
        requested_layout="''${1:-}"
        persisted_layout="$(
          tr -d '[:space:]' < ${lib.escapeShellArg displayLayoutStateFile} 2>/dev/null || true
        )"
        if [ -z "$requested_layout" ]; then
          requested_layout="$persisted_layout"
        fi

        current_description="$(
          jq -r --argjson current "''${current_id:--1}" \
            '.[] | select(.id == $current) | .description' <<<"$sinks"
        )"
        previous_layout_target="$(layout_target "$persisted_layout")"

        # Follow the display only while audio still matches the previous
        # layout's default. Any other live sink is an explicit user override
        # and remains selected across display-state changes.
        if [ -n "$current_description" ] \
          && [ -n "$previous_layout_target" ] \
          && [ "$current_description" != "$previous_layout_target" ]; then
          return
        fi

        select_layout_fallback "$requested_layout"
      }

      reconcile_default() {
        if [ -z "$configured_name" ]; then
          return
        fi
        if jq -e --arg name "$configured_name" \
          'any(.[]; .name == $name)' <<<"$sinks" >/dev/null; then
          return
        fi
        select_layout_fallback
      }

      case "''${1:-cycle}" in
        initialize)
          for ((attempt = 0; attempt < 20; attempt++)); do
            if [ "$(jq '[.[] | select(.name | test("playback[.][0387][.]0$"))] | length' <<<"$sinks")" -ge 4 ]; then
              break
            fi
            sleep 0.25
            load_graph
            sinks="$(get_sinks)"
          done
          while IFS= read -r sink_id; do
            wpctl set-volume "$sink_id" ${lib.escapeShellArg "${toString cfg.audioOutputStartupVolumePercent}%"}
          done < <(
            jq -r '.[] | select(.name | test("playback[.][0387][.]0$")) | .id' \
              <<<"$sinks"
          )
          follow_layout
          exit 0
          ;;
        follow-layout)
          follow_layout
          exit 0
          ;;
        select-name)
          if [ "$#" -ne 2 ]; then
            echo "usage: couch-audio-output select-name NODE_NAME" >&2
            exit 2
          fi
          next_id="$(
            jq -r --arg name "$2" \
              '[.[] | select(.name == $name)][0].id // ""' <<<"$sinks"
          )"
          if [ -z "$next_id" ]; then
            echo "requested audio output is no longer available" >&2
            exit 1
          fi
          set_default "$next_id"
          exit 0
          ;;
        reconcile)
          reconcile_default
          exit 0
          ;;
        prepare-layout)
          follow_layout "''${2:-}"
          # WirePlumber follows the new default target. Give it time to relink
          # live streams while the old HDMI sink still exists; otherwise SDL
          # loses its playback node when the display is parked and Moonlight
          # cannot recover that audio stream without reconnecting.
          sleep 1
          exit 0
          ;;
        status)
          jq -r --argjson current "''${current_id:--1}" \
            '.[] | select(.id == $current) | .description' <<<"$sinks"
          exit 0
          ;;
        cycle)
          next_id="$(
            jq -r --argjson current "''${current_id:--1}" '
              (map(.id) | index($current)) as $index
              | if $index == null then .[0].id
                else .[(($index + 1) % length)].id
                end
            ' <<<"$sinks"
          )"
          ;;
        *)
          echo "usage: couch-audio-output {initialize|follow-layout|select-name NODE_NAME|reconcile|prepare-layout LAYOUT|cycle|status}" >&2
          exit 2
          ;;
      esac

      description="$(
        jq -r --argjson id "$next_id" '.[] | select(.id == $id) | .description' \
          <<<"$sinks"
      )"
      set_default "$next_id"
      hyprctl notify 1 3000 'rgb(a6e3a1)' "Audio output: $description" \
        >/dev/null 2>&1 || true
      printf '%s\n' "$description"
    '';
  };

  audioHealthRecovery = pkgs.writeShellApplication {
    name = "couch-audio-health-recovery";
    runtimeInputs = [
      audioOutputControl
      pkgs.coreutils
      pkgs.systemd
      pkgs.wireplumber
    ];
    text = ''
      case "$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)" in
        direct-*)
          # Direct DRM owns its own local-client lifecycle and audio route.
          exit 0
          ;;
      esac

      if ! systemctl --user --quiet is-active pipewire.service; then
        exit 0
      fi

      probe_audio() {
        timeout --kill-after=1 4 wpctl status >/dev/null 2>&1
      }

      reconcile_audio() {
        timeout --kill-after=1 5 couch-audio-output reconcile >/dev/null 2>&1
      }

      if probe_audio && reconcile_audio; then
        exit 0
      fi
      sleep 2
      if probe_audio && reconcile_audio; then
        exit 0
      fi

      # A failed Bluetooth/HDMI route can wedge WirePlumber while PipeWire and
      # its client streams are still healthy. Restarting only the session
      # manager preserves those streams and lets it rebuild their links.
      systemctl --user restart wireplumber.service
      for _ in 1 2; do
        sleep 1
        if probe_audio && reconcile_audio; then
          exit 0
        fi
      done

      # SDL clients such as Moonlight do not recreate their playback stream
      # after the PipeWire server disappears. Record the active local clients,
      # disconnect them inside their server-side grace window, rebuild audio,
      # select the persisted layout's sink, and immediately reconnect them.
      active_moonlight_units=()
      for moonlight_unit in \
        couch-moonlight-stream.service \
        couch-moonlight-browser-stream.service \
        couch-moonlight-browser-selector.service; do
        if systemctl --user --quiet is-active "$moonlight_unit"; then
          active_moonlight_units+=("$moonlight_unit")
        fi
      done

      dms_was_active=false
      if systemctl --user --quiet is-active couch-merged-dms.service; then
        dms_was_active=true
      fi

      sessions_stopped=false
      restore_sessions() {
        if ! "$sessions_stopped"; then
          return
        fi
        if "$dms_was_active"; then
          systemctl --user start couch-merged-dms.service || true
        fi
        for moonlight_unit in "''${active_moonlight_units[@]}"; do
          systemctl --user start "$moonlight_unit" || true
        done
      }
      trap restore_sessions EXIT

      sessions_stopped=true
      if [ "''${#active_moonlight_units[@]}" -gt 0 ]; then
        systemctl --user stop "''${active_moonlight_units[@]}"
      fi
      if "$dms_was_active"; then
        systemctl --user stop couch-merged-dms.service
      fi

      systemctl --user restart \
        pipewire.service \
        pipewire-pulse.service \
        wireplumber.service

      graph_healthy=false
      for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if probe_audio; then
          graph_healthy=true
          break
        fi
      done
      if ! "$graph_healthy"; then
        echo "audio graph remains unhealthy after a bounded rebuild" >&2
        exit 1
      fi
      if ! reconcile_audio; then
        echo "audio graph recovered but its persisted display route did not" >&2
        exit 1
      fi

      restore_sessions
      sessions_stopped=false
      trap - EXIT
    '';
  };

  audioLayoutSync = pkgs.writeShellApplication {
    name = "couch-audio-follow-layout";
    runtimeInputs = [
      pkgs.coreutils
      waitForStableOutputs
      audioOutputControl
    ];
    text = ''
      couch-wait-for-stable-outputs
      sleep 2

      if timeout --kill-after=1 8 couch-audio-output follow-layout; then
        exit 0
      fi

      ${lib.optionalString cfg.enableAudioHealthRecovery ''
        ${lib.getExe audioHealthRecovery}
        sleep 2
        timeout --kill-after=1 8 couch-audio-output follow-layout
      ''}
    '';
  };

  displayLayoutControl = pkgs.writeShellApplication {
    name = "couch-display-layout";
    runtimeInputs = [
      audioOutputControl
      pkgs.coreutils
      pkgs.hyprland
      pkgs.systemd
    ];
    text = ''
      state_file=${lib.escapeShellArg displayLayoutStateFile}
      current="$(
        if [ -r "$state_file" ]; then
          tr -d '[:space:]' < "$state_file"
        fi
      )"
      case "$current" in
        dual-tvs) current=living-bedroom ;;
        primary-aux) current=living-aux ;;
        secondary-aux) current=bedroom-aux ;;
        solo-primary) current=living ;;
        solo-secondary) current=bedroom ;;
        solo-aux | solo-tertiary) current=aux ;;
        adaptive | all | living-bedroom | living-aux | bedroom-aux | living | bedroom | aux) ;;
        *) current=adaptive ;;
      esac

      case "''${1:-status}" in
        status)
          printf '%s\n' "$current"
          exit 0
          ;;
        cycle)
          case "$current" in
            adaptive) requested=all ;;
            all) requested=living-bedroom ;;
            living-bedroom) requested=living-aux ;;
            living-aux) requested=bedroom-aux ;;
            bedroom-aux) requested=living ;;
            living) requested=bedroom ;;
            bedroom) requested=aux ;;
            *) requested=adaptive ;;
          esac
          ;;
        dual-tvs) requested=living-bedroom ;;
        primary-aux) requested=living-aux ;;
        secondary-aux) requested=bedroom-aux ;;
        solo-primary) requested=living ;;
        solo-secondary) requested=bedroom ;;
        solo-aux | solo-tertiary) requested=aux ;;
        adaptive | all | living-bedroom | living-aux | bedroom-aux | living | bedroom | aux)
          requested="$1"
          ;;
        *)
          echo "usage: couch-display-layout {status|cycle|adaptive|all|living-bedroom|living-aux|bedroom-aux|living|bedroom|aux}" >&2
          exit 2
          ;;
      esac

      ${lib.optionalString cfg.enableAudioOutputCycle ''
        # Migrate live streams before the layout watcher parks the old output.
        # Selecting audio after the HDMI sink disappears is too late for SDL
        # clients such as Moonlight, which keep queuing packets to a dead node.
        timeout --kill-after=1 5 couch-audio-output prepare-layout "$requested" \
          >/dev/null 2>&1 || true
      ''}

      temporary_file="$state_file.tmp"
      printf '%s\n' "$requested" > "$temporary_file"
      mv "$temporary_file" "$state_file"
      ${lib.optionalString cfg.enableAudioOutputCycle ''
        systemctl --user --no-block restart couch-audio-follow-layout.service \
          >/dev/null 2>&1 || true
      ''}
      hyprctl notify 1 3000 'rgb(89b4fa)' "Display layout: $requested" \
        >/dev/null 2>&1 || true
      printf '%s\n' "$requested"
    '';
  };

  couchWorkspace = pkgs.writeShellApplication {
    name = "couch-workspace";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      config_file=${lib.escapeShellArg dynamicMonitorConfigFile}

      active_workspaces() {
        if [ -r "$config_file" ]; then
          sed -n 's/^workspace = \([0-9][0-9]*\),.*/\1/p' "$config_file" \
            | sort -n -u
        else
          printf '1\n2\n3\n'
        fi
      }

      workspace_is_active() {
        requested="$1"
        active_workspaces | grep -Fxq "$requested"
      }

      adjacent_workspace() {
        direction="$1"
        mapfile -t available < <(active_workspaces)
        if ((''${#available[@]} == 0)); then
          available=(1 2 3)
        fi

        current="$(hyprctl activeworkspace -j | jq -r '.id // 1')"
        current_index=0
        for index in "''${!available[@]}"; do
          if [ "''${available[$index]}" = "$current" ]; then
            current_index="$index"
            break
          fi
        done

        if [ "$direction" = next ]; then
          next_index=$(((current_index + 1) % ''${#available[@]}))
        else
          next_index=$(((current_index + ''${#available[@]} - 1) % ''${#available[@]}))
        fi
        printf '%s\n' "''${available[$next_index]}"
      }

      action="''${1:-switch}"
      target="''${2:-}"
      case "$action" in
        next | previous)
          target="$(adjacent_workspace "$action")"
          action=switch
          ;;
        move-next | move-previous)
          target="$(adjacent_workspace "''${action#move-}")"
          action=move
          ;;
        switch | move)
          if ! workspace_is_active "$target"; then
            hyprctl notify 1 2200 'rgb(f9e2af)' \
              "Workspace $target is not active in this display layout" \
              >/dev/null 2>&1 || true
            exit 1
          fi
          ;;
        *)
          echo "usage: couch-workspace {switch NUMBER|move NUMBER|next|previous|move-next|move-previous}" >&2
          exit 2
          ;;
      esac

      case "$action" in
        switch) exec hyprctl dispatch workspace "$target" ;;
        move) exec hyprctl dispatch movetoworkspace "$target" ;;
      esac
    '';
  };

  displayMirrorToggle = pkgs.writeShellApplication {
    name = "couch-display-mirror";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      state_file=${lib.escapeShellArg mirrorStateFile}
      current="$(tr -d '[:space:]' < "$state_file" 2>/dev/null || true)"

      case "''${1:-toggle}" in
        toggle)
          if [ "$current" = 1 ]; then
            requested=0
          else
            requested=1
          fi
          ;;
        on)
          requested=1
          ;;
        off)
          requested=0
          ;;
        status)
          if [ "$current" = 1 ]; then
            echo on
          else
            echo off
          fi
          exit 0
          ;;
        *)
          echo "usage: couch-display-mirror {toggle|on|off|status}" >&2
          exit 2
          ;;
      esac

      if [ "$requested" = 1 ]; then
        external_outputs="$(
          hyprctl -j monitors all 2>/dev/null \
            | jq '[.[] | select(
                .name != "eDP-1" and .name != "LVDS-1"
                and .disabled == false and .dpmsStatus == true
              )] | length' 2>/dev/null \
            || printf '0\n'
        )"
        if [ "$external_outputs" -lt 2 ]; then
          echo "display mirroring requires two connected external outputs" >&2
          exit 1
        fi
      fi

      temporary_file="$state_file.tmp"
      printf '%s\n' "$requested" > "$temporary_file"
      mv "$temporary_file" "$state_file"
    '';
  };

  autoLayoutExternalOutputs = pkgs.writeShellApplication {
    name = "couch-auto-layout-outputs";
    runtimeInputs =
      [
        pkgs.coreutils
        pkgs.hyprland
        pkgs.jq
        pkgs.xrandr
      ]
      ++ lib.optional (cfg.autoMirrorExternalOutputs || cfg.enableMirrorToggle) pkgs.wl-mirror;
    text = ''
      config_file=${lib.escapeShellArg dynamicMonitorConfigFile}
      mirror_state_file=${lib.escapeShellArg mirrorStateFile}
      display_layout_state_file=${lib.escapeShellArg displayLayoutStateFile}
      layout_key=""
      mirror_pid=""

      stop_mirror() {
        if [ -n "$mirror_pid" ] && kill -0 "$mirror_pid" 2>/dev/null; then
          kill "$mirror_pid" 2>/dev/null || true
          wait "$mirror_pid" 2>/dev/null || true
        fi
        mirror_pid=""
      }

      mode_available() {
        output="$1"
        candidate="$2"
        case "$candidate" in
          *@[0-9]*) ;;
          *) return 1 ;;
        esac
        dimensions="''${candidate%@*}"
        refresh="''${candidate##*@}"
        jq -e \
          --arg output "$output" \
          --arg dimensions "$dimensions" \
          --argjson refresh "$refresh" '
            [.[] | select(.name == $output)][0].availableModes // []
            | any(.[];
                startswith($dimensions + "@")
                and (
                  try (
                    (capture("@(?<refresh>[0-9.]+)Hz$").refresh | tonumber) - $refresh
                    | fabs < 1.0
                  ) catch false
                )
              )
          ' <<<"$monitors" >/dev/null
      }

      select_auxiliary_mode() {
        output="$1"
        for candidate in ${lib.escapeShellArgs cfg.autoLayoutSecondaryModes}; do
          if mode_available "$output" "$candidate"; then
            printf '%s\n' "$candidate"
            return
          fi
        done
        printf '%s\n' preferred
      }

      restore_secondary_workspace() {
        target_output="$1"
        [ -n "$target_output" ] || return
        hyprctl dispatch focusmonitor "$target_output" >/dev/null 2>&1 || true
        hyprctl dispatch workspace \
          ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutSecondaryWorkspaces))} \
          >/dev/null 2>&1 || true
      }

      write_layout() {
        source_output="$1"
        source_mode="$2"
        secondary_output="$3"
        secondary_mode="$4"
        tertiary_output="$5"
        tertiary_mode="$6"
        native_mirror="$7"
        secondary_logical=0
        if [ -n "$secondary_output" ] && [ "$native_mirror_requested" != 1 ]; then
          secondary_logical=1
        fi
        allowed_workspaces=${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutPrimaryWorkspaces)}
        if [ "$secondary_logical" = 1 ]; then
          allowed_workspaces="$(
            jq -cn \
              --argjson primary "$allowed_workspaces" \
              --argjson secondary ${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutSecondaryWorkspaces)} \
              '$primary + $secondary'
          )"
        fi
        if [ -n "$tertiary_output" ]; then
          tertiary_workspaces=${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutTertiaryWorkspaces)}
          if [ "$secondary_logical" != 1 ]; then
            # Compact a two-display layout into the first two workspace blocks.
            # The auxiliary output is physically tertiary, but logically it is
            # the second active display when no second TV is selected.
            tertiary_workspaces=${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutSecondaryWorkspaces)}
          fi
          allowed_workspaces="$(
            jq -cn \
              --argjson current "$allowed_workspaces" \
              --argjson tertiary "$tertiary_workspaces" \
              '$current + $tertiary'
          )"
        fi
        temporary_file="$config_file.tmp"
        secondary_position=${lib.escapeShellArg cfg.autoLayoutSecondaryPosition}
        tertiary_position=${lib.escapeShellArg cfg.autoLayoutTertiaryPosition}
        if [ -z "$secondary_output" ] && [ -n "$tertiary_output" ]; then
          tertiary_position=${lib.escapeShellArg cfg.autoLayoutSecondaryPosition}
        elif [ "$native_mirror_requested" = 1 ]; then
          secondary_position=${lib.escapeShellArg autoMirrorSecondaryPosition}
          tertiary_position=${lib.escapeShellArg autoMirrorTertiaryPosition}
        fi
        if [ "$native_mirror" = 1 ]; then
          tertiary_position=${lib.escapeShellArg autoMirrorSecondaryPosition}
        fi

        {
          parked_index=1
          while IFS= read -r parked_output; do
            parked_mode="$(select_auxiliary_mode "$parked_output")"
            parked_position="$((parked_index * 10000))x0"
            printf 'monitor = %s, %s, %s, 1\n' \
              "$parked_output" "$parked_mode" "$parked_position"
            parked_index=$((parked_index + 1))
          done < <(jq -r '.[].name' <<<"$parked_outputs")

          if [ -n "$source_output" ]; then
            printf 'monitor = %s, %s, 0x0, %s\n' \
              "$source_output" \
              "$source_mode" \
              ${lib.escapeShellArg (toString cfg.outputScale)}
            for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutPrimaryWorkspaces)}; do
              default=""
              if [ "$workspace" = ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutPrimaryWorkspaces))} ]; then
                default=", default:true"
              fi
              printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                "$workspace" "$source_output" "$default"
            done
          fi
          if [ -n "$secondary_output" ]; then
            if [ "$native_mirror" = 1 ]; then
              printf 'monitor = %s, %s, 0x0, %s, mirror, %s\n' \
                "$secondary_output" \
                "$secondary_mode" \
                ${lib.escapeShellArg (toString cfg.autoLayoutSecondaryScale)} \
                "$source_output"
            elif [ "$secondary_logical" = 1 ]; then
              printf 'monitor = %s, %s, %s, %s\n' \
                "$secondary_output" \
                "$secondary_mode" \
                "$secondary_position" \
                ${lib.escapeShellArg (toString cfg.autoLayoutSecondaryScale)}
              for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutSecondaryWorkspaces)}; do
                default=""
                if [ "$workspace" = ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutSecondaryWorkspaces))} ]; then
                  default=", default:true"
                fi
                printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                  "$workspace" "$secondary_output" "$default"
              done
            else
              printf 'monitor = %s, %s, %s, %s\n' \
                "$secondary_output" \
                "$secondary_mode" \
                "$secondary_position" \
                ${lib.escapeShellArg (toString cfg.autoLayoutSecondaryScale)}
            fi
          fi
          if [ -n "$tertiary_output" ]; then
            printf 'monitor = %s, %s, %s, %s\n' \
              "$tertiary_output" \
              "$tertiary_mode" \
              "$tertiary_position" \
              ${lib.escapeShellArg (toString cfg.autoLayoutTertiaryScale)}
            tertiary_default_workspace="$(jq -r '.[0]' <<<"$tertiary_workspaces")"
            while read -r workspace; do
              default=""
              if [ "$workspace" = "$tertiary_default_workspace" ]; then
                default=", default:true"
              fi
              printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                "$workspace" "$tertiary_output" "$default"
            done < <(jq -r '.[]' <<<"$tertiary_workspaces")
          fi
        } >"$temporary_file"

        if ! cmp -s "$temporary_file" "$config_file"; then
          mv "$temporary_file" "$config_file"
          hyprctl reload >/dev/null 2>&1 || true
          sleep 0.5
        else
          rm -f "$temporary_file"
        fi

        while IFS= read -r parked_output; do
          hyprctl dispatch dpms off "$parked_output" >/dev/null 2>&1 || true
        done < <(jq -r '.[].name' <<<"$parked_outputs")
        while IFS= read -r active_output; do
          hyprctl dispatch dpms on "$active_output" >/dev/null 2>&1 || true
        done < <(jq -r '.[].name' <<<"$external_monitors")

        if [ -n "$source_output" ]; then
          for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutPrimaryWorkspaces)}; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$source_output" >/dev/null 2>&1 || true
          done
        fi
        if [ "$secondary_logical" = 1 ]; then
          hyprctl dispatch focusmonitor "$secondary_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace \
            ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutSecondaryWorkspaces))} \
            >/dev/null 2>&1 || true
          for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutSecondaryWorkspaces)}; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$secondary_output" >/dev/null 2>&1 || true
          done
        fi
        if [ -n "$tertiary_output" ]; then
          hyprctl dispatch focusmonitor "$tertiary_output" >/dev/null 2>&1 || true
          tertiary_default_workspace="$(jq -r '.[0]' <<<"$tertiary_workspaces")"
          hyprctl dispatch workspace \
            "$tertiary_default_workspace" \
            >/dev/null 2>&1 || true
          while read -r workspace; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$tertiary_output" >/dev/null 2>&1 || true
          done < <(jq -r '.[]' <<<"$tertiary_workspaces")
        fi
        if [ -n "$source_output" ]; then
          while IFS=$'\t' read -r address destination; do
            [ -n "$address" ] || continue
            hyprctl dispatch movetoworkspacesilent \
              "$destination,address:$address" >/dev/null 2>&1 || true
          done < <(
            hyprctl clients -j \
              | jq -r --argjson allowed "$allowed_workspaces" '
                  .[]
                  | .workspace.id as $id
                  | select(
                      $id > 0
                      and $id < 10
                      and ($allowed | index($id) | not)
                    )
                  | [.address, (((.workspace.id - 1) % 3) + 1)]
                  | @tsv
                '
          )
          hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          DISPLAY=:0 xrandr --output "$source_output" --primary >/dev/null 2>&1 || true
        fi
      }

      trap stop_mirror EXIT
      trap 'exit 0' HUP INT TERM

      while true; do
        monitors="$(hyprctl -j monitors all 2>/dev/null || printf '[]')"
        connected_external_monitors="$(
          jq -c '[.[] | select(
            .name != "eDP-1" and .name != "LVDS-1" and .disabled == false
          )]' <<<"$monitors" 2>/dev/null || printf '[]'
        )"

        display_layout=all
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
        display_layout="$(tr -d '[:space:]' < "$display_layout_state_file" 2>/dev/null || true)"
        case "$display_layout" in
          dual-tvs) display_layout=living-bedroom ;;
          primary-aux) display_layout=living-aux ;;
          secondary-aux) display_layout=bedroom-aux ;;
          solo-primary) display_layout=living ;;
          solo-secondary) display_layout=bedroom ;;
          solo-aux | solo-tertiary) display_layout=aux ;;
          adaptive | all | living-bedroom | living-aux | bedroom-aux | living | bedroom | aux) ;;
          *) display_layout=adaptive ;;
        esac
      ''}

        case "$display_layout" in
          adaptive)
            external_monitors="$(
              jq -c '
                [.[] | select(.dpmsStatus == true)]
                | sort_by(.physicalWidth * .physicalHeight)
                | reverse
                | .[:1]
              ' <<<"$connected_external_monitors"
            )"
            # An empty external layout is never valid. If no output is already
            # enabled, retain the physically largest connected output as the
            # primary fallback.
            if [ "$(jq 'length' <<<"$external_monitors")" -eq 0 ]; then
              external_monitors="$(
                jq -c '
                  sort_by(.physicalWidth * .physicalHeight)
                  | reverse
                  | .[:1]
                ' <<<"$connected_external_monitors"
              )"
            fi
            ;;
          all)
            external_monitors="$connected_external_monitors"
            ;;
          living-bedroom)
            external_monitors="$(
              jq -c \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | if ($tvs | length) > 0 then $tvs[:2]
                    else $ranked[:1]
                    end
                end
              ' <<<"$connected_external_monitors"
            )"
            ;;
          living-aux | bedroom-aux)
            external_monitors="$(
              jq -c \
                --arg layout "$display_layout" \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | ([$ranked[] | select(.physicalWidth < $minimum_width)]) as $auxiliary
                  | (if $layout == "living-aux" then
                       ($tvs[0] // $ranked[0])
                     else
                       ($tvs[1] // $tvs[0] // $ranked[0])
                     end) as $tv
                  | [$tv, $auxiliary[0]]
                  | map(select(. != null))
                  | unique_by(.name)
                end
              ' <<<"$connected_external_monitors"
            )"
            ;;
          living | bedroom | aux)
            external_monitors="$(
              jq -c \
                --arg layout "$display_layout" \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | ([$ranked[] | select(.physicalWidth < $minimum_width)]) as $auxiliary
                  | if $layout == "living" then
                      [($tvs[0] // $ranked[0])]
                    elif $layout == "bedroom" then
                      [($tvs[1] // $tvs[0] // $ranked[0])]
                    else
                      [($auxiliary[0] // $tvs[0] // $ranked[0])]
                    end
                end
              ' <<<"$connected_external_monitors"
            )"
            ;;
        esac

        active_output_names="$(jq -c '[.[].name]' <<<"$external_monitors")"
        parked_outputs="$(
          jq -c --argjson active "$active_output_names" '
            [.[] | select(.name as $name | ($active | index($name) | not))]
          ' <<<"$connected_external_monitors"
        )"
        source_output="$(
          jq -r --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
            if length == 0 then ""
            else
              (map(select(.physicalWidth >= $minimum_width))) as $preferred
              | (if ($preferred | length) > 0 then $preferred else . end)
              | max_by(.physicalWidth * .physicalHeight)
              | .name
            end
          ' <<<"$external_monitors"
        )"
        secondary_output=""
        secondary_mode=""
        tertiary_output=""
        tertiary_mode=""
        source_mode=""
        if [ -n "$source_output" ]; then
          source_mode="$(select_auxiliary_mode "$source_output")"
          secondary_output="$(
            jq -r \
              --arg source "$source_output" \
              --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
              [.[] | select(
                .name != $source and .physicalWidth >= $minimum_width
              )]
              | max_by(.physicalWidth * .physicalHeight).name // ""
            ' <<<"$external_monitors"
          )"
          tertiary_output="$(
            jq -r \
              --arg source "$source_output" \
              --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
              [.[] | select(
                .name != $source and .physicalWidth < $minimum_width
              )]
              | max_by(.physicalWidth * .physicalHeight).name // ""
            ' <<<"$external_monitors"
          )"
          if [ -n "$secondary_output" ]; then
            secondary_mode="$(select_auxiliary_mode "$secondary_output")"
          fi
          if [ -n "$tertiary_output" ]; then
            tertiary_mode="$(select_auxiliary_mode "$tertiary_output")"
          fi
        fi

        native_mirror_requested=0
        ${lib.optionalString cfg.enableMirrorToggle ''
        native_mirror_requested="$(tr -d '[:space:]' < "$mirror_state_file" 2>/dev/null || true)"
        if [ "$native_mirror_requested" != 1 ]; then
          native_mirror_requested=0
        fi
      ''}
        mirror_output_mode=${lib.escapeShellArg autoMirrorOutputMode}
        if [ "$native_mirror_requested" = 1 ] \
          && [ -n "$mirror_output_mode" ] \
          && [ -n "$source_output" ] \
          && [ -n "$secondary_output" ] \
          && mode_available "$source_output" "$mirror_output_mode" \
          && mode_available "$secondary_output" "$mirror_output_mode"; then
          source_mode="$mirror_output_mode"
          secondary_mode="$mirror_output_mode"
        fi
        native_mirror=0
        native_mirror_allowed=${
        if cfg.forceSoftwareMirror
        then "0"
        else "1"
      }
        primary_dimensions="''${source_mode%@*}"
        secondary_dimensions="''${secondary_mode%@*}"
        if [ "$native_mirror_requested" = 1 ] \
          && [ "$native_mirror_allowed" = 1 ] \
          && [ -n "$secondary_output" ] \
          && [ "$secondary_dimensions" = "$primary_dimensions" ]; then
          native_mirror=1
        fi

        parked_output_names="$(jq -r '[.[].name] | join(",")' <<<"$parked_outputs")"
        new_layout_key="$display_layout:$source_output:$source_mode:$secondary_output:$secondary_mode:$tertiary_output:$tertiary_mode:$parked_output_names:$native_mirror"
        if [ "$new_layout_key" != "$layout_key" ]; then
          stop_mirror
          write_layout \
            "$source_output" \
            "$source_mode" \
            "$secondary_output" \
            "$secondary_mode" \
            "$tertiary_output" \
            "$tertiary_mode" \
            "$native_mirror"
          layout_key="$new_layout_key"
        fi

        ${lib.optionalString (cfg.autoMirrorExternalOutputs || cfg.enableMirrorToggle) ''
        software_mirror=0
        ${lib.optionalString cfg.autoMirrorExternalOutputs ''
          software_mirror=1
        ''}
        ${lib.optionalString cfg.enableMirrorToggle ''
          if [ "$native_mirror_requested" = 1 ] && [ "$native_mirror" != 1 ]; then
            software_mirror=1
          fi
        ''}

        if [ "$software_mirror" = 1 ] \
          && [ -n "$source_output" ] \
          && [ -n "$secondary_output" ]; then
          if [ -z "$mirror_pid" ] || ! kill -0 "$mirror_pid" 2>/dev/null; then
            hyprctl dispatch focusmonitor "$secondary_output" >/dev/null 2>&1 || true
            hyprctl dispatch workspace \
              ${lib.escapeShellArg (toString cfg.autoMirrorWorkspace)} \
              >/dev/null 2>&1 || true
            wl-mirror \
              --fullscreen-output "$secondary_output" \
              --scaling fit \
              --title "Couch mirror $source_output" \
              "$source_output" &
            mirror_pid=$!
            sleep 0.5
            hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
            hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          fi
        elif [ -n "$mirror_pid" ]; then
          stop_mirror
          restore_secondary_workspace "$secondary_output"
          if [ -n "$source_output" ]; then
            hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
            hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          fi
        fi
      ''}

        sleep 1
      done
    '';
  };

  dmsSession = pkgs.writeShellApplication {
    name = "couch-dms";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi
      export PATH="$HOME/.nix-profile/bin:$PATH"
      exec "$dms" run
    '';
  };

  mergedDmsSession = pkgs.writeShellApplication {
    name = "couch-merged-dms";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      displayLayoutControl
      displayMirrorToggle
      audioOutputControl
    ];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      if [ "$mode" != merged ]; then
        exit 0
      fi

      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi
      export PATH="$HOME/.nix-profile/bin:$PATH"

      config_home=${lib.escapeShellArg mergedDmsConfigDirectory}
      settings_directory="$config_home/DankMaterialShell"
      cheatsheets_directory="$settings_directory/cheatsheets"
      rm -rf "$config_home"
      install -d -m 0700 "$settings_directory" "$cheatsheets_directory"
      install -m 0600 ${mergedDmsSettingsFile} "$settings_directory/settings.json"
      install -m 0600 ${mergedDmsCheatsheetFile} \
        "$cheatsheets_directory/xps-media-center.json"

      plugin_settings="$HOME/.config/DankMaterialShell/plugin_settings.json"
      if [ -e "$plugin_settings" ]; then
        ln -s "$plugin_settings" "$settings_directory/plugin_settings.json"
      fi

      plugins_directory="$HOME/.config/DankMaterialShell/plugins"
      if [ -d "$plugins_directory" ]; then
        ln -s "$plugins_directory" "$settings_directory/plugins"
      fi

      export XDG_CONFIG_HOME="$config_home"
      exec "$dms" run
    '';
  };

  mergedDmsCondition = pkgs.writeShellApplication {
    name = "couch-merged-dms-condition";
    runtimeInputs = [pkgs.gnugrep];
    text = ''
      grep -qx merged ${lib.escapeShellArg modeStateFile}
    '';
  };

  waitForStableOutputs = pkgs.writeShellApplication {
    name = "couch-wait-for-stable-outputs";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      # Give the layout daemon the first scheduling turn, then require the
      # visible output geometry to remain unchanged for one full second.
      sleep 0.5
      previous=""
      stable=0
      for _attempt in $(seq 1 100); do
        current="$(
          hyprctl -j monitors all 2>/dev/null \
            | jq -c '[
                .[]
                | select(.disabled == false and .dpmsStatus == true)
                | {
                    name,
                    x,
                    y,
                    width,
                    height,
                    refreshRate,
                    scale
                  }
              ] | sort_by(.name)' 2>/dev/null \
            || printf '[]\n'
        )"
        if [ "$current" != '[]' ] && [ "$current" = "$previous" ]; then
          stable=$((stable + 1))
        else
          stable=0
        fi
        previous="$current"
        if [ "$stable" -ge 10 ]; then
          exit 0
        fi
        sleep 0.1
      done
    '';
  };

  sessionSplashLaunch = pkgs.writeShellApplication {
    name = "couch-session-splash-launch";
    runtimeInputs = [waitForStableOutputs];
    text = ''
      couch-wait-for-stable-outputs
      # The compositor can render before a dock-connected TV has completed its
      # physical link recovery. Retained XPS boot timings put that gap at about
      # three seconds; keep the overlay loaded but do not consume its animation
      # clock during that interval.
      export NIXBOX_SPLASH_SETTLE_MS=3000
      exec ${
        if cfg.sessionSplashCommand == null
        then "${pkgs.coreutils}/bin/true"
        else cfg.sessionSplashCommand
      }
    '';
  };

  sessionPowerAction = pkgs.writeShellApplication {
    name = "couch-session-power-action";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      case "''${1:-}" in
        reboot)
          action=reboot
          mode=reboot
          ;;
        poweroff)
          action=poweroff
          mode=shutdown
          ;;
        *)
          echo "usage: couch-session-power-action {reboot|poweroff}" >&2
          exit 2
          ;;
      esac

      export NIXBOX_SPLASH_SETTLE_MS=0
      ${cfg.sessionSplashCommand} "$mode" &
      splash_pid=$!
      sleep 3.7
      if ! systemctl "$action"; then
        kill "$splash_pid" 2>/dev/null || true
        wait "$splash_pid" 2>/dev/null || true
        exit 1
      fi
      wait "$splash_pid" 2>/dev/null || true
    '';
  };

  mergedDmsServiceControl = pkgs.writeShellApplication {
    name = "couch-merged-dms-service-control";
    runtimeInputs = [
      pkgs.systemd
      waitForStableOutputs
    ];
    text = ''
      systemctl --user import-environment \
        WAYLAND_DISPLAY \
        HYPRLAND_INSTANCE_SIGNATURE \
        XDG_CURRENT_DESKTOP \
        DBUS_SESSION_BUS_ADDRESS
      couch-wait-for-stable-outputs
      exec systemctl --user restart couch-merged-dms.service
    '';
  };

  mergedUiControl = pkgs.writeShellApplication {
    name = "couch-merged-ui";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      if [ "$mode" != merged ]; then
        exit 0
      fi

      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        exit 0
      fi

      # DMS is presentation, not part of the stream lifecycle.  A wedged IPC
      # request must never hold a Moonlight unit in stop-post until systemd
      # marks the otherwise cleanly stopped stream as failed.
      dms_call() {
        timeout \
          --foreground \
          --signal=TERM \
          --kill-after=0.25 \
          0.5 \
          "$dms" ipc call "$@" \
          >/dev/null 2>&1
      }

      case "''${1:-}" in
        refresh)
          for unit in \
            couch-moonlight-stream.service \
            couch-moonlight-browser-stream.service \
            couch-moonlight-browser-selector.service; do
            if systemctl --user --quiet is-active "$unit"; then
              exec "$0" game
            fi
          done
          exec "$0" browser
          ;;
        game)
          dms_call notifications enableDoNotDisturbIndefinitely || true
          dms_call notifications dismissAllPopups || true
          dms_call bar hide index 0 || true
          dms_call dock hide || true
          ;;
        browser)
          for ((attempt = 0; attempt < 2; attempt++)); do
            if dms_call bar reveal index 0; then
              break
            fi
            sleep 0.1
          done
          dms_call bar autoHide index 0 || true
          dms_call dock reveal || true
          dms_call dock autoHide || true
          dms_call notifications disableDoNotDisturb || true
          ;;
        *)
          echo "usage: couch-merged-ui {refresh|game|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  sessionMode = pkgs.writeShellApplication {
    name = "nixbox-mode";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.systemd
      activeKeyboardLayout
    ];
    text = ''
      mode_file=${lib.escapeShellArg modeStateFile}
      persist_state() {
        state_file="$1"
        state_value="$2"
        state_tmp="$(mktemp "$state_file.XXXXXX")"
        printf '%s\n' "$state_value" > "$state_tmp"
        chmod 0644 "$state_tmp"
        mv -f "$state_tmp" "$state_file"
      }
      current="$(tr -d '[:space:]' < "$mode_file" 2>/dev/null || true)"
      current_mode="''${current%%:*}"
      supported_modes="couch${
        lib.optionalString (cfg.desktopSessionCommand != null) "|desktop"
      }${lib.optionalString cfg.enableMergedProfile "|merged"}${lib.optionalString directDrmStreamEnabled "|direct-stream"}${lib.optionalString directDrmBrowserEnabled "|direct-browser"}${
        lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled) "|direct-private"
      }"

      if [ "$#" -eq 0 ]; then
        printf '%s\n' "''${current_mode:-${cfg.defaultSessionMode}}"
        exit 0
      fi

      case "$1" in
        couch${
        lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
      }${lib.optionalString cfg.enableMergedProfile " | merged"})
          if [ "$1" = "$current_mode" ]; then
            printf 'Nixbox is already configured for %s mode\n' "$1"
            exit 0
          fi
          persist_state "$mode_file" "$1"
          ${lib.optionalString persistentDirectDrmBrowserDefault ''
        case "$current_mode" in
          direct-*)
            # Moonlight's EGLFS process ignores the graceful signal from
            # greetd. End only this user's local client after persisting
            # the explicit recovery mode so the wrapper cannot overwrite it.
            pkill -KILL -x moonlight >/dev/null 2>&1 || true
            ;;
        esac
      ''}
          printf 'Switching Nixbox to %s mode\n' "$1"
          ;;
        ${lib.optionalString (directDrmStreamEnabled || directDrmBrowserEnabled) ''
        ${lib.optionalString directDrmStreamEnabled "direct-stream"}${
          lib.optionalString (directDrmStreamEnabled && directDrmBrowserEnabled) " | "
        }${lib.optionalString directDrmBrowserEnabled "direct-browser"}${
          lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled) " | direct-private"
        })
          case "$current_mode" in
            couch${
          lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
        }${lib.optionalString cfg.enableMergedProfile " | merged"})
              return_mode="$current_mode"
              ${lib.getExe activeKeyboardLayout} \
                > ${lib.escapeShellArg directDrmKeyboardLayoutFile}
              ${lib.optionalString cfg.directDrmAutoSelectOutput ''
          ${lib.getExe directDrmOutputSnapshot}
        ''}
              ;;
            direct-*)
              return_mode="$(
                tr -d '[:space:]' \
                  < ${lib.escapeShellArg directDrmReturnModeFile} \
                  2>/dev/null \
                  || true
              )"
              case "$return_mode" in
                couch${
          lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
        }${lib.optionalString cfg.enableMergedProfile " | merged"}${
          lib.optionalString persistentDirectDrmBrowserDefault " | direct-browser"
        }) ;;
                *) return_mode=${lib.escapeShellArg cfg.defaultSessionMode} ;;
              esac
              ${lib.optionalString cfg.directDrmAutoSelectOutput ''
          if [ ! -s ${lib.escapeShellArg directDrmKmsConfigFile} ]; then
            echo "No saved direct DRM output is available" >&2
            exit 1
          fi
        ''}
              ;;
            *)
              return_mode=${lib.escapeShellArg cfg.defaultSessionMode}
              ${lib.getExe activeKeyboardLayout} \
                > ${lib.escapeShellArg directDrmKeyboardLayoutFile}
              ${lib.optionalString cfg.directDrmAutoSelectOutput ''
          ${lib.getExe directDrmOutputSnapshot}
        ''}
              ;;
          esac
          persist_state ${lib.escapeShellArg directDrmReturnModeFile} "$return_mode"
            # Stop compositor clients while their Wayland/XWayland connections
            # are still valid. Letting greetd tear them down first can leave
            # otherwise expected disconnects recorded as failed user units.
            systemctl --user stop \
              couch-moonlight-stream.service \
              couch-moonlight-browser-stream.service \
              couch-moonlight-browser-selector.service \
              couch-protected-browser.service \
              couch-dms.service \
              couch-merged-dms.service \
              kdeconnect.service \
              waynergy.service \
              xdg-desktop-portal-gtk.service \
              >/dev/null 2>&1 || true
            systemctl --user reset-failed \
              couch-moonlight-stream.service \
              couch-moonlight-browser-stream.service \
              couch-moonlight-browser-selector.service \
              couch-protected-browser.service \
              couch-dms.service \
              couch-merged-dms.service \
              kdeconnect.service \
              waynergy.service \
              xdg-desktop-portal-gtk.service \
              >/dev/null 2>&1 || true
          boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
          persist_state "$mode_file" "$1:$boot_id"
          printf 'Switching Nixbox to %s mode\n' "$1"
          ;;
      ''}
        *)
          echo "usage: nixbox-mode [$supported_modes]" >&2
          exit 2
          ;;
      esac
    '';
  };

  couchApplications = pkgs.runCommand "couch-session-applications" {} ''
    mkdir -p "$out/share/applications"

    ${lib.optionalString cfg.enableLocalBrowser ''
      cat > "$out/share/applications/couch-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Couch)
      Comment=Open the couch web browser
      Exec=${lib.getExe couchBrowser}
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString (cfg.enableLocalBrowser && cfg.fallbackBrowserPackage != null) ''
      cat > "$out/share/applications/couch-browser-fallback.desktop" <<EOF
      [Desktop Entry]
      Name=Brave (Couch fallback)
      Comment=Open the compatibility web browser
      Exec=${lib.getExe couchFallbackBrowser.package}
      Icon=brave-browser
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString browserStreamEnabled ''
      cat > "$out/share/applications/couch-remote-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Remote)
      Comment=Stream the public Helium browser through Moonlight and Wolf
      Exec=${lib.getExe couchStreamControl} remote-browser
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString browserSelectorEnabled ''
      cat > "$out/share/applications/couch-private-browser.desktop" <<EOF
      [Desktop Entry]
      Name=User (Remote)
      Comment=Open the PIN-protected remote user profile
      Exec=${lib.getExe couchStreamControl} private-browser
      Icon=system-users
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString directDrmBrowserEnabled ''
      cat > "$out/share/applications/couch-direct-drm-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Direct display)
      Comment=Stream Helium with Moonlight owning the display
      Exec=${lib.getExe sessionMode} direct-browser
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF

      ${lib.optionalString browserSelectorEnabled ''
        cat > "$out/share/applications/couch-direct-drm-private.desktop" <<EOF
        [Desktop Entry]
        Name=User (Direct display)
        Comment=Open the protected remote user profile with Moonlight owning the display
        Exec=${lib.getExe sessionMode} direct-private
        Icon=system-users
        Terminal=false
        Type=Application
        Categories=Network;WebBrowser;
        EOF
      ''}
    ''}

    ${lib.optionalString directDrmStreamEnabled ''
      cat > "$out/share/applications/couch-direct-drm-stream.desktop" <<EOF
      [Desktop Entry]
      Name=Steam Stream (Direct display)
      Comment=Stream Steam with Moonlight owning the display
      Exec=${lib.getExe sessionMode} direct-stream
      Icon=steam
      Terminal=false
      Type=Application
      Categories=Game;
      EOF
    ''}

    ${lib.optionalString cfg.enableControllerShortcuts ''
      cat > "$out/share/applications/couch-steam-stream.desktop" <<EOF
      [Desktop Entry]
      Name=Steam Stream
      Comment=Start Steam Big Picture through Moonlight
      Exec=${lib.getExe couchStreamControl} start
      Icon=steam
      Terminal=false
      Type=Application
      Categories=Game;
      EOF
    ''}

    ${lib.optionalString (cfg.desktopSessionCommand != null) ''
      cat > "$out/share/applications/xps-desktop-mode.desktop" <<EOF
      [Desktop Entry]
      Name=Switch to Desktop Mode
      Comment=Leave the couch session and start the normal desktop
      Exec=${lib.getExe sessionMode} desktop
      Icon=preferences-desktop
      Terminal=false
      Type=Application
      Categories=System;
      EOF

      cat > "$out/share/applications/xps-couch-mode.desktop" <<EOF
      [Desktop Entry]
      Name=Switch to Couch Mode
      Comment=Leave the desktop and start the TV couch session
      Exec=${lib.getExe sessionMode} couch
      Icon=video-display
      Terminal=false
      Type=Application
      Categories=System;
      EOF

      ${lib.optionalString cfg.enableMergedProfile ''
        cat > "$out/share/applications/xps-merged-mode.desktop" <<EOF
        [Desktop Entry]
        Name=Switch to Merged Couch Mode
        Comment=Use the controller-first TV session with an auto-hiding DMS shell
        Exec=${lib.getExe sessionMode} merged
        Icon=video-display
        Terminal=false
        Type=Application
        Categories=System;
        EOF
      ''}
    ''}
  '';

  hyprlandConfig = pkgs.writeText "moonlight-hyprland.conf" ''
    monitor = , ${defaultOutputMode}, auto, ${toString cfg.outputScale}
    ${lib.concatMapStringsSep "\n" (
        output: "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}"
      )
      mirrorSourceOutputs}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source: "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}, mirror, ${source}"
      )
      cfg.mirrorOutputs
    )}
    ${lib.concatStringsSep "\n" (map (rule: "monitor = ${rule}") cfg.extraMonitorRules)}
    ${lib.concatStringsSep "\n" (map (rule: "workspace = ${rule}") cfg.extraWorkspaceRules)}
    ${lib.optionalString dynamicExternalLayoutEnabled "source = ${dynamicMonitorConfigFile}"}
    ${lib.optionalString cfg.disableInternalDisplay ''
      monitor = eDP-1, disable
      monitor = LVDS-1, disable
    ''}

    env = QT_QPA_PLATFORM,wayland
    env = QT_QPA_PLATFORMTHEME,gtk3
    env = QT_QPA_PLATFORMTHEME_QT6,gtk3
    ${lib.optionalString (cfg.cursorThemePackage != null) ''
      env = XCURSOR_THEME,${cfg.cursorTheme}
      env = XCURSOR_SIZE,${toString cfg.cursorSize}
    ''}

    exec-once = ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${pkgs.systemd}/bin/systemctl --user restart kdeconnect.service"}
    exec-once = ${pkgs.systemd}/bin/systemctl --user start waynergy.service
    exec-once = ${pkgs.systemd}/bin/systemctl --user start xdg-desktop-portal-gtk.service
    ${lib.optionalString dynamicExternalLayoutEnabled "exec-once = ${lib.getExe autoLayoutExternalOutputs}"}
    ${lib.optionalString (
      cfg.sessionSplashCommand != null
    ) "exec-once = ${lib.getExe sessionSplashLaunch}"}
    ${lib.optionalString cfg.autoStartBrowser "exec-once = ${
      lib.getExe (
        if cfg.preferRemoteBrowserAtStartup
        then couchBrowserStartup
        else couchBrowser
      )
    }"}
    ${lib.optionalString cfg.autoStartStream "exec-once = [workspace 1 silent] ${lib.getExe moonlightSession}"}
    ${lib.optionalString cfg.enableControllerShortcuts "exec-once = ${lib.getExe controllerDaemon}"}
    ${lib.optionalString cfg.enableAudioOutputCycle "exec-once = ${lib.getExe audioOutputControl} initialize"}
    # Hyprland's portal does not implement RemoteDesktop. Keep KDE Connect and
    # couch browsers on XWayland so its phone keyboard, clicks, and scrolling
    # can be injected through XTest. Translate XTest-only pointer movement into
    # Hyprland coordinates; the bridge ignores native physical/Wayland motion.
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${lib.getExe pointerSync}"}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source: "exec-once = ${lib.getExe softwareMirror} ${lib.escapeShellArg output} ${lib.escapeShellArg source}"
      )
      cfg.softwareMirrorOutputs
    )}
    # Import the live compositor environment immediately above, then hand DMS
    # to systemd so a transient startup failure or later crash cannot leave the
    # shell absent for the remainder of the session.
    ${lib.optionalString cfg.enableDms "exec-once = ${pkgs.systemd}/bin/systemctl --user start couch-dms.service"}
    ${lib.optionalString cfg.enableMergedProfile "exec-once = ${lib.getExe mergedDmsServiceControl}"}

    input {
      kb_layout = ${cfg.keyboardLayouts}
      kb_options = ${cfg.keyboardOptions}
      numlock_by_default = true

      touchpad {
        natural_scroll = true
      }
    }

    # The couch controls must remain available while Moonlight or another
    # fullscreen client asks the compositor to inhibit global shortcuts.
    binds {
      disable_keybind_grabbing = true
    }

    general {
      gaps_in = 0
      gaps_out = 0
      border_size = 0
    }

    decoration {
      rounding = 0

      shadow {
        enabled = false
      }
    }

    animations {
      enabled = false
    }

    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      background_color = rgb(0b0c0f)
    }

    cursor {
      # Couch pointers are often controlled from a phone or another computer.
      # Keep the cursor visible long enough to reacquire it between gestures.
      inactive_timeout = ${toString cfg.remotePointerInactiveTimeout}
      # Network input backends can expose absolute axes even when they are
      # semantically mice. Never let that classification hide Waynergy or KDE
      # Connect motion; retain the normal inactivity timeout above.
      hide_on_touch = false
    }

    windowrule = match:class CouchBrowser, workspace 2
    bind = SUPER, 1, exec, ${lib.getExe couchWorkspace} switch 1
    bind = SUPER, 2, exec, ${lib.getExe couchWorkspace} switch 2
    bind = SUPER, 3, exec, ${lib.getExe couchWorkspace} switch 3
    bind = SUPER, 4, exec, ${lib.getExe couchWorkspace} switch 4
    bind = SUPER, 5, exec, ${lib.getExe couchWorkspace} switch 5
    bind = SUPER, 6, exec, ${lib.getExe couchWorkspace} switch 6
    bind = SUPER, 7, exec, ${lib.getExe couchWorkspace} switch 7
    bind = SUPER, 8, exec, ${lib.getExe couchWorkspace} switch 8
    bind = SUPER, 9, exec, ${lib.getExe couchWorkspace} switch 9
    ${
      if cfg.enableControllerShortcuts
      then "bind = SUPER, M, exec, ${lib.getExe couchStreamControl} start"
      else "bind = SUPER, M, workspace, 1"
    }
    bind = SUPER, B, exec, ${lib.getExe couchStreamControl} browser
    ${lib.optionalString browserStreamEnabled "bind = SUPER, R, exec, ${lib.getExe couchStreamControl} remote-browser"}
    ${lib.optionalString browserSelectorEnabled "bind = SUPER SHIFT, R, exec, ${lib.getExe couchStreamControl} private-browser"}
    ${lib.optionalString cfg.enableMirrorToggle "bind = SUPER SHIFT, M, exec, ${lib.getExe displayMirrorToggle} toggle"}
    ${lib.optionalString cfg.enableAdaptiveDisplayLayout "bind = SUPER SHIFT, D, exec, ${lib.getExe displayLayoutControl} cycle"}
    ${lib.optionalString cfg.enableAudioOutputCycle "bind = SUPER SHIFT, A, exec, ${lib.getExe audioOutputControl} cycle"}
    bind = SUPER, H, exec, ${lib.getExe couchControlHelp}
    ${lib.optionalString cfg.enableLocalBrowser "bind = SUPER, V, exec, ${lib.getExe couchBrowserNewWindow}"}
    ${lib.optionalString (
      cfg.protectedBrowserPackage != null
    ) "bind = SUPER, Z, exec, ${lib.getExe protectedBrowser}"}
    ${lib.optionalString cfg.enableLocalUtilities "bind = ALT, RETURN, exec, ${lib.getExe couchTerminal}"}
    ${lib.optionalString (
      cfg.enableDms || cfg.enableMergedProfile
    ) "bind = SUPER, SPACE, exec, $HOME/.nix-profile/bin/dms ipc call spotlight toggle"}
    bind = SUPER, W, exec, ${lib.getExe closeActiveWindow}
    bind = SUPER, RETURN, fullscreen
    bind = SUPER, S, togglefloating

    bind = SUPER, J, exec, ${lib.getExe couchWorkspace} previous
    bind = SUPER, K, exec, ${lib.getExe couchWorkspace} next
    bind = SUPER, down, exec, ${lib.getExe couchWorkspace} previous
    bind = SUPER, up, exec, ${lib.getExe couchWorkspace} next
    bind = SUPER, TAB, workspace, previous

    bind = SUPER SHIFT, J, exec, ${lib.getExe couchWorkspace} move-previous
    bind = SUPER SHIFT, K, exec, ${lib.getExe couchWorkspace} move-next
    bind = SUPER SHIFT, down, exec, ${lib.getExe couchWorkspace} move-previous
    bind = SUPER SHIFT, up, exec, ${lib.getExe couchWorkspace} move-next
    bind = SUPER SHIFT, 1, exec, ${lib.getExe couchWorkspace} move 1
    bind = SUPER SHIFT, 2, exec, ${lib.getExe couchWorkspace} move 2
    bind = SUPER SHIFT, 3, exec, ${lib.getExe couchWorkspace} move 3
    bind = SUPER SHIFT, 4, exec, ${lib.getExe couchWorkspace} move 4
    bind = SUPER SHIFT, 5, exec, ${lib.getExe couchWorkspace} move 5
    bind = SUPER SHIFT, 6, exec, ${lib.getExe couchWorkspace} move 6
    bind = SUPER SHIFT, 7, exec, ${lib.getExe couchWorkspace} move 7
    bind = SUPER SHIFT, 8, exec, ${lib.getExe couchWorkspace} move 8
    bind = SUPER SHIFT, 9, exec, ${lib.getExe couchWorkspace} move 9

    bindel = , XF86AudioRaiseVolume, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%+
    bindel = , XF86AudioLowerVolume, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%-
    bindl = , XF86AudioMute, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindel = , F10, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%+
    bindel = , F9, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%-
    bindl = , F8, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle

    # Emergency exit back to greetd if the couch session cannot be closed normally.
    bind = SUPER SHIFT, escape, exit
    bind = SUPER SHIFT, Q, exit
  '';

  sessionLauncher = pkgs.writeShellScript "moonlight-hyprland-session" ''
    # Hyprland writes its startup banner and backend discovery to the launch
    # TTY before the first frame. Its own per-session log remains available
    # under XDG_RUNTIME_DIR, so keep the media-center handoff visually quiet.
    exec ${pkgs.hyprland}/bin/start-hyprland -- --config ${hyprlandConfig} \
      >/dev/null 2>&1
  '';

  sessionPackage = pkgs.writeTextFile {
    name = "moonlight-hyprland-session";
    destination = "/share/wayland-sessions/moonlight-hyprland.desktop";
    passthru.providedSessions = ["moonlight-hyprland"];
    text = ''
      [Desktop Entry]
      Name=Couch (Hyprland)
      Comment=Moonlight, browser, and phone-friendly TV session
      Exec=${sessionLauncher}
      Type=Application
      DesktopNames=Hyprland
    '';
  };

  sessionCommand =
    if cfg.enableCompositedSession
    then sessionLauncher
    else lib.getExe directDrmBrowserSession;

  sessionDispatcher = pkgs.writeShellApplication {
    name = "couch-session-dispatcher";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      persist_mode() {
        mode_tmp="$(mktemp ${lib.escapeShellArg "${modeStateFile}.XXXXXX"})"
        printf '%s\n' "$1" > "$mode_tmp"
        chmod 0644 "$mode_tmp"
        mv -f "$mode_tmp" ${lib.escapeShellArg modeStateFile}
      }
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      mode_name="''${mode%%:*}"
      mode_token=""
      if [ "$mode" != "$mode_name" ]; then
        mode_token="''${mode#*:}"
      fi
      if [ "$mode_name" != merged ]; then
        systemctl --user stop couch-merged-dms.service >/dev/null 2>&1 || true
      fi
      case "$mode_name" in
        ${lib.optionalString (cfg.desktopSessionCommand != null) ''
        desktop)
          exec ${cfg.desktopSessionCommand}
          ;;
      ''}
        ${lib.optionalString cfg.enableMergedProfile ''
        merged)
          exec ${sessionCommand}
          ;;
      ''}
        ${lib.optionalString directDrmStreamEnabled ''
        direct-stream)
          boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
          if [ "$mode_token" = "$boot_id" ]; then
            exec ${lib.getExe directDrmStreamSession}
          fi
          persist_mode ${lib.escapeShellArg cfg.defaultSessionMode}
          exec ${sessionCommand}
          ;;
      ''}
        ${lib.optionalString directDrmBrowserEnabled ''
        direct-browser)
          boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
          if [ "$mode_token" = "$boot_id" ]${lib.optionalString persistentDirectDrmBrowserDefault " || [ -z \"$mode_token\" ]"}; then
            exec ${lib.getExe directDrmBrowserSession}
          fi
          persist_mode ${lib.escapeShellArg cfg.defaultSessionMode}
          exec ${sessionCommand}
          ;;
        ${lib.optionalString browserSelectorEnabled ''
          direct-private)
            boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
            if [ "$mode_token" = "$boot_id" ]; then
              exec ${lib.getExe directDrmBrowserSelectorSession}
            fi
            persist_mode ${lib.escapeShellArg cfg.defaultSessionMode}
            exec ${sessionCommand}
            ;;
        ''}
      ''}
        couch | *)
          exec ${sessionCommand}
          ;;
      esac
    '';
  };
in {
  options.services.moonlight-client = {
    enable = lib.mkEnableOption "a dedicated Moonlight Hyprland session";

    enableCompositedSession = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Provide the Hyprland couch session and use it as the recovery path.
        Disable this for direct-display appliances whose only sessions let
        Moonlight own DRM through EGLFS.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.moonlight-qt;
      defaultText = lib.literalExpression "pkgs.moonlight-qt";
      description = "Moonlight package used by the dedicated session.";
    };

    autoLoginUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "User to log directly into the Moonlight session on boot, or null to use the display manager.";
    };

    relaunchOnExit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Relaunch Moonlight when it exits so the session remains controller accessible.";
    };

    autoStartStream = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Launch Moonlight when the couch session starts.";
    };

    autoStartBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Launch the couch browser when the couch session starts.";
    };

    preferRemoteBrowserAtStartup = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Prefer the configured remote browser when the couch session starts,
        falling back to the local couch browser when its Sunshine endpoint is
        unavailable.
      '';
    };

    browserStartupTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds to wait for the remote browser before starting the local fallback.";
    };

    sessionSplashCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional non-blocking command launched before couch-session applications.";
    };

    moonlightPlatform = lib.mkOption {
      type = lib.types.enum [
        "wayland"
        "xcb"
      ];
      default = "wayland";
      description = "Qt platform used by Moonlight; xcb permits KDE Connect XTest input.";
    };

    streamHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Paired Moonlight host to stream immediately, or null to open the host chooser.";
    };

    streamApplication = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Moonlight application to launch on streamHost, or null to open the host chooser.";
    };

    streamLocalAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Preferred RFC 1918 address for the direct stream host.";
    };

    streamRemoteAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "VPN fallback address for the direct stream host.";
    };

    streamEndpointMode = lib.mkOption {
      type = lib.types.enum [
        "lan-only"
        "lan-first"
        "remote-only"
      ];
      default = "lan-first";
      description = ''
        Endpoint policy for the direct stream. LAN-only and remote-only pin
        every saved Moonlight address field to the selected endpoint; LAN-first
        retains an explicit remote fallback.
      '';
    };

    browserStreamHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Paired Moonlight host providing the controller-launched remote browser.";
    };

    browserStreamApplication = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Moonlight application used as the public remote browser.";
    };

    browserStreamSelectorApplication = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional Moonlight application used as a separate protected-profile
        selector on the same remote browser host.
      '';
    };

    browserStreamSelectorHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional independent paired Moonlight host for the protected browser
        selector. Null keeps the selector on browserStreamHost.
      '';
    };

    browserStreamSelectorPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = ''
        Optional nonstandard HTTP port for an isolated protected browser
        coordinator.
      '';
    };

    browserStreamSelectorLocalAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional RFC 1918 address for an independent protected-browser
        selector host. Null inherits browserStreamLocalAddress.
      '';
    };

    browserStreamSelectorRemoteAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional VPN fallback address for an independent protected-browser
        selector host. Null inherits browserStreamRemoteAddress.
      '';
    };

    browserStreamSelectorProfileDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional absolute directory containing isolated XDG config, cache, and
        data homes for the protected browser selector. Set this when the public
        browser and selector must stream concurrently from the same host.
      '';
    };

    enableDirectDrmBrowserStreams = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Offer one-shot browser sessions where Moonlight owns DRM through
        EGLFS instead of rendering through Hyprland. Exiting the stream
        automatically returns to the previous graphical session mode.
      '';
    };

    enableDirectDrmStream = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Offer a one-shot primary Moonlight stream where Moonlight owns DRM
        through EGLFS instead of rendering through Hyprland. Exiting the
        stream automatically returns to the previous graphical session mode.
      '';
    };

    directDrmAutoSelectOutput = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Before entering a one-shot direct-DRM session, snapshot the focused
        powered Hyprland output and generate a Qt EGLFS KMS configuration that
        uses its DRM device and current pixel dimensions while turning off
        other connected outputs on that device. This is intended for
        multi-GPU or multi-output couch hosts; fixed single-output appliances
        can retain EGLFS discovery.
      '';
    };

    directDrmFixedOutput = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            device = lib.mkOption {
              type = lib.types.str;
              example = "/dev/dri/card0";
              description = "DRM device used by the fixed direct-display output.";
            };

            connector = lib.mkOption {
              type = lib.types.str;
              example = "HDMI-A-1";
              description = "Kernel DRM connector used by the fixed direct-display output.";
            };

            mode = lib.mkOption {
              type = lib.types.str;
              example = "1920x1080@60";
              description = "Exact Qt EGLFS KMS mode used by the fixed direct-display output.";
            };

            disabledConnectors = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              example = [
                "eDP-1"
                "DP-2"
              ];
              description = ''
                Other connectors on the DRM device that Qt EGLFS must disable
                while the fixed direct-display output owns scanout.
              '';
            };
          };
        }
      );
      default = null;
      description = ''
        Generate a static Qt EGLFS KMS configuration for a fixed direct-DRM
        output. This prevents EGLFS from replacing the configured mode with the
        display's preferred mode or presenting on another connected output.
      '';
    };

    directDrmAudioOutputByConnector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "DP-1" = "Living room TV";
        "HDMI-A-1" = "Desk display";
      };
      description = ''
        PipeWire sinks selected together with each connector in a direct-DRM
        session. Connector names use their kernel/Hyprland form; each value
        must match the sink's PipeWire node name, WirePlumber description, or
        nickname. The composited couch session also uses this association when
        exactly one external connector is enabled, preventing a semantic
        display-layout fallback from selecting another connector's HDMI PCM.
      '';
    };

    directDrmExtraEnvironment = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["MOONLIGHT_VIDEO_STATS_LOG_INTERVAL_MS=5000"];
      description = "Additional NAME=VALUE environment entries for direct-DRM Moonlight sessions.";
    };

    directDrmLogToJournal = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Mirror direct-DRM Moonlight output to the system journal while
        retaining it on the appliance's virtual console.
      '';
    };

    directDrmStreamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional Moonlight arguments used only by the direct-DRM primary stream.";
    };

    browserStreamLocalAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Preferred RFC 1918 address for the remote browser host.";
    };

    browserStreamRemoteAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "VPN fallback address for the remote browser host.";
    };

    browserStreamEndpointMode = lib.mkOption {
      type = lib.types.enum [
        "lan-only"
        "lan-first"
        "remote-only"
      ];
      default = "lan-first";
      description = ''
        Endpoint policy for the browser stream. LAN-only and remote-only pin
        every saved Moonlight address field to the selected endpoint; LAN-first
        retains an explicit remote fallback.
      '';
    };

    browserStreamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional Moonlight arguments used only for the remote browser stream.";
    };

    browserAbsoluteMouseSensitivity = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 1.0;
      description = ''
        Client-side pointer multiplier used by polled absolute-mouse browser
        sessions. Values above one increase physical pointer sensitivity
        without changing the remote absolute coordinate mapping.
      '';
    };

    browserAbsoluteMousePollIntervalMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = ''
        Poll interval in milliseconds for physical pointer input in
        absolute-mouse browser sessions.
      '';
    };

    browserShowLocalCursor = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Show Moonlight's local cursor during browser streams. Disable this for
        direct-display clients where the local cursor otherwise remains parked
        over the streamed desktop.
      '';
    };

    browserStreamLayoutCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        Optional command that aligns a newly started remote browser with the
        main local keyboard. COUCH_KEYBOARD_LAYOUT and
        COUCH_STREAM_APPLICATION are exported for the command.
      '';
    };

    browserStreamPrepareCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        Optional command run before connecting to the public remote browser.
        This can clear client-specific stale server state after an unclean
        local exit without affecting other cooperative clients.
      '';
    };

    streamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional arguments passed to the direct Moonlight stream command.";
    };

    streamHostStartCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Optional command that starts the remote stream host before Moonlight.";
    };

    streamReadinessHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host whose Sunshine port must become reachable before Moonlight starts.";
    };

    streamReadinessPort = lib.mkOption {
      type = lib.types.port;
      default = 47989;
      description = "TCP port used to determine whether the stream host is ready.";
    };

    streamHostControlPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = ''
        TCP port used to choose the LAN-first host address exported to the
        stream host start command as COUCH_STREAM_START_TARGET.
      '';
    };

    streamStartupTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Seconds to wait for the stream host after requesting startup.";
    };

    enableControllerShortcuts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Listen for held controller shortcuts that start streaming or return to the browser.";
    };

    enableDirectModeInputShortcuts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run a persistent non-grabbing keyboard and controller listener for
        direct-display session switching. The listener sleeps outside direct
        modes and survives compositor and greetd session replacement.
      '';
    };

    controllerDeviceName = lib.mkOption {
      type = lib.types.str;
      default = "Pro Controller";
      description = "Linux input device name used for couch controller shortcuts.";
    };

    controllerHoldSeconds = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Time a controller shortcut must be held before it is activated.";
    };

    enableDms = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start DMS from the user's Home Manager profile in the dedicated session.";
    };

    enableMergedProfile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Offer a third dedicated session profile with isolated, couch-friendly DMS settings.";
    };

    mergedDmsSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        acMonitorTimeout = 0;
        acLockTimeout = 0;
        acSuspendTimeout = 0;
        acPostLockMonitorTimeout = 0;
        batteryMonitorTimeout = 0;
        batteryLockTimeout = 0;
        batterySuspendTimeout = 0;
        batteryPostLockMonitorTimeout = 0;
        loginctlLockIntegration = false;
        lockBeforeSuspend = false;
        lockAtStartup = false;
        fadeToLockEnabled = false;
        fadeToDpmsEnabled = false;
        soundsEnabled = false;
        # DMS's native surfaces are otherwise too small to read at couch
        # distance on a 1440p television. This config is isolated from the
        # normal desktop profile.
        fontScale = 2.0;
        showDock = true;
        dockAutoHide = true;
        dockSmartAutoHide = true;
        notificationOverlayEnabled = false;
        barConfigs = [
          {
            id = "merged";
            name = "Couch Bar";
            enabled = true;
            position = 0;
            screenPreferences = ["all"];
            showOnLastDisplay = true;
            leftWidgets = [
              "launcherButton"
              "workspaceSwitcher"
              "focusedWindow"
            ];
            centerWidgets = [
              "music"
              "clock"
            ];
            rightWidgets = [
              "dankDisplayControl"
              "systemTray"
              "notificationButton"
              "battery"
              "controlCenterButton"
            ];
            spacing = 4;
            innerPadding = 4;
            bottomGap = 0;
            transparency = 1.0;
            widgetTransparency = 1.0;
            autoHide = true;
            autoHideStrict = true;
            autoHideDelay = 250;
            showOnWindowsOpen = false;
            openOnOverview = false;
            visible = true;
            popupGapsAuto = true;
            popupGapsManual = 4;
            useOverlayLayer = false;
          }
        ];
      };
      description = "DMS settings used only by the isolated merged couch profile.";
    };

    enableKdeConnect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable KDE Connect and start its daemon in the dedicated session.";
    };

    kdeConnectScrollIntervalMs = lib.mkOption {
      type = lib.types.ints.between 0 1000;
      default = kdeConnectInputDefaults.scrollIntervalMs;
      description = ''
        Minimum interval between KDE Connect XTest wheel steps in
        milliseconds. Zero preserves upstream packet-for-packet scrolling.
      '';
    };

    kdeConnectPointerSensitivity = lib.mkOption {
      type = lib.types.numbers.positive;
      default = kdeConnectInputDefaults.pointerSensitivity;
      description = "Maximum KDE Connect pointer gain during fast motion.";
    };

    kdeConnectPointerPrecisionSensitivity = lib.mkOption {
      type = lib.types.numbers.positive;
      default = kdeConnectInputDefaults.pointerPrecisionSensitivity;
      description = "KDE Connect pointer gain during slow, precise motion.";
    };

    kdeConnectPointerAccelerationStart = lib.mkOption {
      type = lib.types.numbers.nonnegative;
      default = kdeConnectInputDefaults.pointerAccelerationStart;
      description = "Pointer speed where KDE Connect acceleration starts.";
    };

    kdeConnectPointerAccelerationFull = lib.mkOption {
      type = lib.types.numbers.positive;
      default = kdeConnectInputDefaults.pointerAccelerationFull;
      description = "Pointer speed where KDE Connect reaches maximum gain.";
    };

    keyboardLayouts = lib.mkOption {
      type = lib.types.str;
      default = "us,no";
      description = "Comma-separated XKB layouts used by the dedicated couch session, in default-first order.";
    };

    keyboardLayoutDeviceOverrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = ''
        Case-insensitive keyboard-name substrings that select a layout for a
        streamed browser when the matching device is connected. Attribute
        names are layout identifiers from keyboardLayouts.
      '';
    };

    keyboardOptions = lib.mkOption {
      type = lib.types.str;
      default = "grp:alt_shift_toggle";
      description = "XKB options used by the dedicated couch session.";
    };

    cursorThemePackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Optional XCursor theme package installed for the dedicated couch session.";
    };

    cursorTheme = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "XCursor theme name used by the dedicated couch session.";
    };

    cursorSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Cursor size in pixels used by the dedicated couch session.";
    };

    remotePointerInactiveTimeout = lib.mkOption {
      type = lib.types.ints.between 0 20;
      default = kdeConnectInputDefaults.cursorInactiveTimeoutSeconds;
      description = ''
        Seconds to retain the couch cursor after remote pointer activity.
        Zero disables inactivity hiding.
      '';
    };

    browserPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.helium;
      defaultText = lib.literalExpression "pkgs.helium";
      description = "Browser package used by the couch browser launcher.";
    };

    enableLocalBrowser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install and expose the local browser fallback in the dedicated session.";
    };

    enableLocalUtilities = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install and expose local couch-session utilities such as the terminal launcher.";
    };

    browserScaleFactor = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Chromium device scale factor used by couch browser launchers.";
    };

    browserPresentationScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = ''
        UI and cursor presentation class requested from a remote browser
        capsule. This does not change streamed video resolution.
      '';
    };

    terminalPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.foot;
      defaultText = lib.literalExpression "pkgs.foot";
      description = "Terminal package opened by the couch-session terminal shortcut.";
    };

    browserProfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "helium-couch";
      description = "Directory below ~/.local/share used for the couch browser profile.";
    };

    fallbackBrowserPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.brave;
      defaultText = lib.literalExpression "pkgs.brave";
      description = "Optional compatibility browser package used by the couch session.";
    };

    fallbackBrowserProfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "brave-couch";
      description = "Directory below ~/.local/share used for the fallback browser profile.";
    };

    protectedBrowserPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Browser package whose data directory is kept in a password-protected gocryptfs mount.";
    };

    protectedBrowserName = lib.mkOption {
      type = lib.types.str;
      default = "Private browser";
      description = "Name shown for the password-protected browser launcher.";
    };

    protectedBrowserIcon = lib.mkOption {
      type = lib.types.str;
      default = "web-browser";
      description = "Icon name or absolute path used by the protected browser desktop entry.";
    };

    protectedBrowserCommandName = lib.mkOption {
      type = lib.types.str;
      default = "couch-protected-browser";
      description = "Command name installed for the protected browser launcher.";
    };

    protectedBrowserEncryptedDirectory = lib.mkOption {
      type = lib.types.str;
      default = "couch-protected-browser";
      description = "Directory below ~/.local/share that stores the encrypted browser data.";
    };

    protectedBrowserRuntimeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "couch-protected-browser";
      description = "Directory below XDG_RUNTIME_DIR used for the unlocked browser mount.";
    };

    protectedBrowserLegacyProfileDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional existing browser data directory to migrate into an empty protected profile.";
    };

    desktopSessionCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Command for the normal desktop session, or null to disable persistent mode switching.";
    };

    defaultSessionMode = lib.mkOption {
      type = lib.types.enum [
        "couch"
        "desktop"
        "direct-browser"
        "merged"
      ];
      default = "couch";
      description = ''
        Session mode initialized on activation and boot. Direct browser mode
        persistently starts the public browser with Moonlight owning DRM;
        other direct modes remain one-shot requests.
      '';
    };

    disableInternalDisplay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable common laptop panels while retaining the preferred external display.";
    };

    outputScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used for the Moonlight display.";
    };

    outputMode = lib.mkOption {
      type = lib.types.str;
      default = "preferred";
      description = "Hyprland mode used for the Moonlight display.";
    };

    mirrorOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "DP-2" = "DP-1";
      };
      description = "External outputs to mirror, expressed as target-to-source connector mappings.";
    };

    mirrorOutputMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Shared mode for mirrored outputs, or null to use outputMode.";
    };

    extraMonitorRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["DP-2, 3840x2160@60, 2560x0, 2"];
      description = "Additional Hyprland monitor rule bodies applied after the default and native mirror rules.";
    };

    extraWorkspaceRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["10, monitor:DP-2, default:true"];
      description = "Additional Hyprland workspace rule bodies for fixed multi-output couch layouts.";
    };

    softwareMirrorOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "DP-2" = "DP-1";
      };
      description = "Outputs mirrored in a supervised fullscreen wl-mirror client, expressed as target-to-source mappings.";
    };

    autoMirrorExternalOutputs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Supervise a software mirror from the discovered primary external output to the secondary output.";
    };

    enableMirrorToggle = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable an on-demand mirror toggle from the primary to the secondary external output, using native mirroring for matching modes and software mirroring otherwise.";
    };

    forceSoftwareMirror = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use the supervised wl-mirror path for on-demand mirroring even when output modes match.";
    };

    enableAdaptiveDisplayLayout = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Preserve the currently active external output with persistent all-output and solo-output recovery modes.";
    };

    enableAudioOutputCycle = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable keyboard and controller shortcuts that cycle the available PipeWire audio sinks.";
    };

    enableAudioHealthRecovery = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reconcile vanished couch audio routes and recover an unresponsive
        graph by reconnecting active local Moonlight clients.
      '';
    };

    audioOutputStartupVolumePercent = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 40;
      description = "Safe startup volume applied to the persistent local couch audio sinks.";
    };

    autoLayoutExternalOutputs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Dynamically lay out external outputs and move their workspace sets across connector changes.";
    };

    autoLayoutSecondaryModes = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = ["1920x1080@60"];
      description = "Preferred modes for automatically discovered auxiliary outputs, in priority order.";
    };

    autoLayoutSecondaryPosition = lib.mkOption {
      type = lib.types.str;
      default = "2560x0";
      description = "Hyprland position used by the automatically discovered secondary output.";
    };

    autoMirrorSecondaryPosition = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hyprland position used by the secondary output while on-demand mirroring is enabled, or null to retain autoLayoutSecondaryPosition.";
    };

    autoLayoutSecondaryScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used by the automatically discovered secondary output.";
    };

    autoLayoutTertiaryPosition = lib.mkOption {
      type = lib.types.str;
      default = "5120x0";
      description = "Hyprland position used by the automatically discovered tertiary output.";
    };

    autoMirrorTertiaryPosition = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hyprland position used by the tertiary output while on-demand mirroring is enabled, or null to retain autoLayoutTertiaryPosition.";
    };

    autoLayoutTertiaryScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used by the automatically discovered tertiary output.";
    };

    autoLayoutPrimaryMinPhysicalWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      description = "Minimum reported physical width in millimetres for an external output to become the automatic mirror source.";
    };

    autoLayoutPrimaryWorkspaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.ints.positive;
      default = [
        1
        2
        3
        4
        5
      ];
      description = "Persistent workspaces assigned to the discovered primary output.";
    };

    autoLayoutSecondaryWorkspaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.ints.positive;
      default = [
        6
        7
        8
        9
        10
      ];
      description = "Persistent workspaces assigned while the secondary output is an independent logical display.";
    };

    autoLayoutTertiaryWorkspaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.ints.positive;
      default = [
        11
        12
        13
      ];
      description = "Persistent workspaces assigned while the tertiary output is an independent logical display.";
    };

    autoMirrorWorkspace = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Dedicated workspace used by the automatic fullscreen software mirror.";
    };

    fallbackOutputMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Mode to apply when the external display does not enter outputMode, or null to keep Hyprland's result.";
    };

    preferHdmiAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Select the first available HDMI sink before starting Moonlight.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      [moonlightPackage]
      ++ lib.optionals cfg.enableCompositedSession [
        couchApplications
        couchStreamControl
        closeActiveWindow
        moonlightStreamStart
      ]
      ++ lib.optionals cfg.enableLocalUtilities [
        cfg.terminalPackage
        couchTerminal
      ]
      ++ lib.optionals cfg.enableLocalBrowser [
        cfg.browserPackage
        couchBrowser
        couchBrowserStartup
        couchBrowserNewWindow
      ]
      ++ lib.optional (
        browserSelectorEnabled && cfg.browserStreamSelectorProfileDirectory != null
      )
      browserSelectorPair
      ++ lib.optional cfg.enableControllerShortcuts controllerDaemon
      ++ lib.optional cfg.enableControllerShortcuts couchControlHelp
      ++ lib.optional directModeInputShortcutsEnabled directModeInputDaemon
      ++ lib.optional (cfg.cursorThemePackage != null) cfg.cursorThemePackage
      ++ lib.optionals cfg.enableKdeConnect [
        pointerSync
        (lib.hiPrio kdeConnectDbusServiceOverride)
      ]
      ++ lib.optional cfg.enableMergedProfile mergedDmsSession
      ++ lib.optional cfg.enableMergedProfile mergedUiControl
      ++ lib.optional (cfg.softwareMirrorOutputs != {}) softwareMirror
      ++ lib.optional cfg.enableMirrorToggle displayMirrorToggle
      ++ lib.optional cfg.enableAdaptiveDisplayLayout displayLayoutControl
      ++ lib.optional cfg.enableAudioOutputCycle audioOutputControl
      ++ lib.optional cfg.enableAudioOutputCycle audioLayoutSync
      ++ lib.optional (cfg.sessionSplashCommand != null) sessionPowerAction
      ++ lib.optional dynamicExternalLayoutEnabled autoLayoutExternalOutputs
      ++ lib.optional (
        cfg.enableLocalBrowser && cfg.fallbackBrowserPackage != null
      )
      cfg.fallbackBrowserPackage
      ++ lib.optional (
        cfg.enableLocalBrowser && cfg.fallbackBrowserPackage != null
      )
      couchFallbackBrowser.package
      ++ lib.optional (cfg.protectedBrowserPackage != null) protectedBrowser
      ++ lib.optional sessionModeSwitchEnabled sessionMode;
    services.displayManager.sessionPackages = lib.optional cfg.enableCompositedSession sessionPackage;

    # Install udev rules for common controllers, including Steam hardware.
    hardware.steam-hardware.enable = true;

    programs.kdeconnect.enable = cfg.enableKdeConnect;

    hardware.uinput = lib.mkIf kdeConnectDirectInputEnabled {
      enable = true;
    };

    # Route both eager startup and D-Bus activation through one supervised
    # XWayland daemon. The preload shim preserves KDE Connect's XTest keyboard,
    # click and scroll path while forwarding pointer motion rejected by
    # XWayland to the session-local Hyprland bridge.
    systemd.user.services.kdeconnect = lib.mkIf cfg.enableKdeConnect {
      description = "KDE Connect with Hyprland pointer integration";
      environment = {
        KDECONNECT_SCROLL_INTERVAL_MS = toString cfg.kdeConnectScrollIntervalMs;
        KDECONNECT_POINTER_SENSITIVITY = toString cfg.kdeConnectPointerSensitivity;
        KDECONNECT_POINTER_PRECISION_SENSITIVITY =
          toString cfg.kdeConnectPointerPrecisionSensitivity;
        KDECONNECT_POINTER_ACCELERATION_START =
          toString cfg.kdeConnectPointerAccelerationStart;
        KDECONNECT_POINTER_ACCELERATION_FULL =
          toString cfg.kdeConnectPointerAccelerationFull;
        QT_QPA_PLATFORM = "xcb";
        LD_PRELOAD = "${kdeConnectHyprlandInput}/lib/libkdeconnect-hypr-pointer-shim.so";
      };
      serviceConfig = {
        Type = "dbus";
        BusName = "org.kde.kdeconnect";
        ExecStart = lib.getExe kdeConnectSessionLauncher;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.nixbox-direct-input =
      lib.mkIf (
        directModeInputShortcutsEnabled || kdeConnectDirectInputEnabled
      ) {
        description = "Direct-display shortcuts and KDE Connect input bridge";
        wantedBy = ["default.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe directModeInputDaemon;
          Restart = "always";
          RestartSec = 1;
        };
      };

    systemd.user.services.couch-moonlight-stream = lib.mkIf cfg.enableControllerShortcuts {
      description = "Controller-launched Moonlight stream";
      restartIfChanged = false;
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "-${lib.getExe mergedUiControl} game";
        ExecStart = lib.getExe moonlightStreamStart;
        ExecStopPost = "-${lib.getExe mergedUiControl} refresh";
        TimeoutStartSec = cfg.streamStartupTimeout + 30;
        TimeoutStopSec = 3;
        KillMode = "control-group";
        SendSIGKILL = true;
      };
    };

    systemd.user.services.couch-moonlight-browser-stream =
      lib.mkIf (
        cfg.enableCompositedSession && browserStreamEnabled
      ) {
        description = "Controller-launched remote browser stream";
        restartIfChanged = false;
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "-${lib.getExe mergedUiControl} game";
          ExecStart = lib.getExe moonlightBrowserSession;
          ExecStopPost = "-${lib.getExe mergedUiControl} refresh";
          TimeoutStopSec = 3;
          KillMode = "control-group";
          SendSIGKILL = true;
        };
      };

    systemd.user.services.couch-moonlight-browser-selector =
      lib.mkIf (
        cfg.enableCompositedSession && browserSelectorEnabled
      ) {
        description = "PIN-protected remote browser selector";
        restartIfChanged = false;
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "-${lib.getExe mergedUiControl} game";
          ExecStart = lib.getExe moonlightBrowserSelectorSession;
          ExecStopPost = "-${lib.getExe mergedUiControl} refresh";
          TimeoutStopSec = 3;
          KillMode = "control-group";
          SendSIGKILL = true;
        };
      };

    systemd.user.services.couch-protected-browser =
      lib.mkIf (
        cfg.enableCompositedSession && cfg.protectedBrowserPackage != null
      ) {
        description = "Independent protected couch browser supervisor";
        serviceConfig = {
          Type = "exec";
          ExecStart = lib.getExe protectedBrowserSession;
        };
      };

    systemd.user.services.xdg-desktop-portal-gtk =
      lib.mkIf (
        cfg.enableCompositedSession && persistentDirectDrmBrowserDefault
      ) {
        overrideStrategy = "asDropin";
        serviceConfig.ExecCondition = compositorSessionCondition;
      };

    systemd.user.services.couch-dms = lib.mkIf cfg.enableDms {
      description = "Supervised DMS shell for the dedicated couch session";
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe dmsSession;
        Restart = "always";
        RestartSec = 2;
        SuccessExitStatus = 143;
      };
    };

    systemd.user.services.couch-merged-dms = lib.mkIf cfg.enableMergedProfile {
      description = "Supervised DMS shell for the merged couch session";
      serviceConfig = {
        Type = "simple";
        ExecCondition = lib.getExe mergedDmsCondition;
        ExecStart = lib.getExe mergedDmsSession;
        Restart = "always";
        RestartSec = 2;
        SuccessExitStatus = 143;
      };
    };

    systemd.user.services.couch-audio-health-recovery = lib.mkIf cfg.enableAudioHealthRecovery {
      description = "Reconcile couch audio and recover stalled routes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe audioHealthRecovery;
        TimeoutStartSec = 60;
      };
    };

    systemd.user.services.couch-audio-follow-layout = lib.mkIf cfg.enableAudioOutputCycle {
      description = "Select couch audio after the display layout settles";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe audioLayoutSync;
        TimeoutStartSec = 45;
      };
    };

    systemd.user.timers.couch-audio-health-recovery = lib.mkIf cfg.enableAudioHealthRecovery {
      description = "Reconcile couch audio routes and verify responsiveness";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "5s";
        AccuracySec = "1s";
        Unit = "couch-audio-health-recovery.service";
      };
    };

    services.greetd.settings.initial_session = lib.mkIf (cfg.autoLoginUser != null) {
      command =
        if sessionModeSwitchEnabled
        then lib.getExe sessionDispatcher
        else sessionCommand;
      user = cfg.autoLoginUser;
    };

    # greetd validates default_session even when initial_session handles the
    # automatic login. Direct-only appliances have no desktop greeter, so use
    # the same dispatcher as their recovery session as well.
    services.greetd.settings.default_session =
      lib.mkIf (
        cfg.autoLoginUser != null && !cfg.enableCompositedSession
      ) {
        command =
          if sessionModeSwitchEnabled
          then lib.getExe sessionDispatcher
          else sessionCommand;
        user = cfg.autoLoginUser;
      };

    # A persistent direct-display appliance must recover its initial session
    # after an operator or service restart as well as after a mode-file change.
    systemd.services.greetd.preStart = lib.mkIf persistentDirectDrmBrowserDefault ''
      rm -f /run/greetd.run
    '';

    # Direct-display appliances have no fallback greeter or compositor. Keep
    # the display session supervised even when greetd's child exits cleanly.
    systemd.services.greetd.serviceConfig = lib.mkIf persistentDirectDrmBrowserDefault {
      Restart = "always";
      RestartSec = 2;
    };

    systemd.tmpfiles.rules =
      lib.optional (
        cfg.autoLoginUser != null && (sessionModeSwitchEnabled || cfg.enableAdaptiveDisplayLayout)
      ) "d ${modeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional sessionModeSwitchEnabled "${
        if persistentDirectDrmBrowserDefault
        then "f+"
        else "f"
      } ${modeStateFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}"
      ++ lib.optional ((directDrmStreamEnabled || directDrmBrowserEnabled) && cfg.autoLoginUser != null)
      "${
        if persistentDirectDrmBrowserDefault
        then "f+"
        else "f"
      } ${directDrmReturnModeFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}"
      ++ lib.optional ((directDrmStreamEnabled || directDrmBrowserEnabled) && cfg.autoLoginUser != null)
      "f ${directDrmKeyboardLayoutFile} 0644 ${cfg.autoLoginUser} root - ${builtins.head (lib.splitString "," cfg.keyboardLayouts)}"
      ++ lib.optional (
        cfg.directDrmAutoSelectOutput && cfg.autoLoginUser != null
      ) "f ${directDrmKmsConfigFile} 0644 ${cfg.autoLoginUser} root -"
      ++ lib.optional (
        cfg.autoLoginUser != null && cfg.enableAdaptiveDisplayLayout
      ) "f ${displayLayoutStateFile} 0644 ${cfg.autoLoginUser} root - adaptive"
      ++ lib.optional (
        cfg.autoLoginUser != null && dynamicExternalLayoutEnabled
      ) "d ${runtimeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional (
        cfg.autoLoginUser != null && dynamicExternalLayoutEnabled
      ) "f ${dynamicMonitorConfigFile} 0644 ${cfg.autoLoginUser} root -"
      ++ lib.optional (
        cfg.autoLoginUser != null && cfg.enableMirrorToggle
      ) "f ${mirrorStateFile} 0644 ${cfg.autoLoginUser} root - 0";

    systemd.paths.couch-session-mode-switch = lib.mkIf sessionModeSwitchEnabled {
      description = "Watch for Nixbox session mode changes";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = modeStateFile;
        Unit = "couch-session-mode-switch.service";
      };
    };

    systemd.services.couch-session-mode-switch = lib.mkIf sessionModeSwitchEnabled {
      description = "Restart greetd after a Nixbox session mode change";
      serviceConfig.Type = "oneshot";
      script = ''
        # initial_session runs once per boot unless greetd's ephemeral marker is
        # cleared. A deliberate mode change should auto-login immediately.
        rm -f /run/greetd.run
        ${pkgs.systemd}/bin/systemctl try-restart greetd.service
      '';
    };

    assertions = [
      {
        assertion = cfg.enableCompositedSession || cfg.defaultSessionMode == "direct-browser";
        message = "services.moonlight-client without a composited session requires direct-browser as its default session mode";
      }
      {
        assertion =
          cfg.kdeConnectPointerPrecisionSensitivity
          <= cfg.kdeConnectPointerSensitivity;
        message = "KDE Connect precision pointer gain must not exceed its maximum gain";
      }
      {
        assertion =
          cfg.kdeConnectPointerAccelerationStart
          < cfg.kdeConnectPointerAccelerationFull;
        message = "KDE Connect pointer acceleration full speed must exceed its start speed";
      }
      {
        assertion = cfg.autoLoginUser == null || config.services.greetd.enable;
        message = "services.moonlight-client.autoLoginUser requires services.greetd.enable";
      }
      {
        assertion = cfg.desktopSessionCommand == null || cfg.autoLoginUser != null;
        message = "services.moonlight-client.desktopSessionCommand requires autoLoginUser";
      }
      {
        assertion = !cfg.enableDirectDrmStream || cfg.autoLoginUser != null;
        message = "services.moonlight-client.enableDirectDrmStream requires autoLoginUser";
      }
      {
        assertion = !cfg.enableDirectDrmStream || directStreamEnabled;
        message = "services.moonlight-client.enableDirectDrmStream requires a configured primary stream";
      }
      {
        assertion = !cfg.directDrmAutoSelectOutput || (directDrmStreamEnabled || directDrmBrowserEnabled);
        message = "services.moonlight-client.directDrmAutoSelectOutput requires a configured direct-DRM stream";
      }
      {
        assertion = cfg.directDrmFixedOutput == null || (directDrmStreamEnabled || directDrmBrowserEnabled);
        message = "services.moonlight-client.directDrmFixedOutput requires a configured direct-DRM stream";
      }
      {
        assertion = !cfg.directDrmAutoSelectOutput || cfg.directDrmFixedOutput == null;
        message = "services.moonlight-client directDrmAutoSelectOutput and directDrmFixedOutput are mutually exclusive";
      }
      {
        assertion = cfg.directDrmAudioOutputByConnector == {} || directDrmKmsConfigEnabled;
        message = "services.moonlight-client.directDrmAudioOutputByConnector requires a direct DRM KMS configuration";
      }
      {
        assertion = !cfg.enableDirectDrmBrowserStreams || cfg.autoLoginUser != null;
        message = "services.moonlight-client.enableDirectDrmBrowserStreams requires autoLoginUser";
      }
      {
        assertion = !cfg.enableDirectDrmBrowserStreams || browserStreamEnabled;
        message = "services.moonlight-client.enableDirectDrmBrowserStreams requires a configured browser stream";
      }
      {
        assertion = cfg.defaultSessionMode != "merged" || cfg.enableMergedProfile;
        message = "services.moonlight-client.defaultSessionMode = merged requires enableMergedProfile";
      }
      {
        assertion = cfg.defaultSessionMode != "direct-browser" || directDrmBrowserEnabled;
        message = "services.moonlight-client.defaultSessionMode = direct-browser requires a configured direct browser stream";
      }
      {
        assertion = (cfg.streamHost == null) == (cfg.streamApplication == null);
        message = "services.moonlight-client.streamHost and streamApplication must be set together";
      }
      {
        assertion = (cfg.browserStreamHost == null) == (cfg.browserStreamApplication == null);
        message = "services.moonlight-client.browserStreamHost and browserStreamApplication must be set together";
      }
      {
        assertion = (cfg.streamLocalAddress == null) == (cfg.streamRemoteAddress == null);
        message = "services.moonlight-client stream local and remote addresses must be set together";
      }
      {
        assertion = !streamEndpointPolicyEnabled || directStreamEnabled;
        message = "services.moonlight-client stream endpoint policy requires a direct stream";
      }
      {
        assertion = (cfg.browserStreamLocalAddress == null) == (cfg.browserStreamRemoteAddress == null);
        message = "services.moonlight-client browser stream local and remote addresses must be set together";
      }
      {
        assertion = !browserStreamEndpointPolicyEnabled || browserStreamEnabled;
        message = "services.moonlight-client browser endpoint policy requires a browser stream";
      }
      {
        assertion = !cfg.preferRemoteBrowserAtStartup || (cfg.autoStartBrowser && browserStreamEnabled);
        message = ''
          services.moonlight-client.preferRemoteBrowserAtStartup requires
          autoStartBrowser and a configured remote browser stream
        '';
      }
      {
        assertion =
          !cfg.autoStartBrowser
          || cfg.enableLocalBrowser
          || (cfg.preferRemoteBrowserAtStartup && browserStreamEnabled);
        message = ''
          services.moonlight-client.autoStartBrowser requires a local browser
          or a preferred remote browser stream
        '';
      }
      {
        assertion = cfg.browserStreamSelectorApplication == null || browserStreamEnabled;
        message = "services.moonlight-client browser selector requires a browser stream host and application";
      }
      {
        assertion = cfg.browserStreamSelectorHost == null || cfg.browserStreamSelectorApplication != null;
        message = "services.moonlight-client.browserStreamSelectorHost requires a browser selector";
      }
      {
        assertion = cfg.browserStreamSelectorPort == null || cfg.browserStreamSelectorApplication != null;
        message = "services.moonlight-client.browserStreamSelectorPort requires a browser selector";
      }
      {
        assertion =
          (cfg.browserStreamSelectorLocalAddress == null)
          == (cfg.browserStreamSelectorRemoteAddress == null);
        message = "services.moonlight-client selector local and remote addresses must be set together";
      }
      {
        assertion =
          cfg.browserStreamSelectorLocalAddress
          == null
          || cfg.browserStreamSelectorApplication != null;
        message = "services.moonlight-client selector addresses require a browser selector";
      }
      {
        assertion =
          cfg.browserStreamSelectorProfileDirectory
          == null
          || lib.hasPrefix "/" cfg.browserStreamSelectorProfileDirectory;
        message = "services.moonlight-client.browserStreamSelectorProfileDirectory must be absolute";
      }
      {
        assertion = cfg.controllerHoldSeconds > 0.0;
        message = "services.moonlight-client.controllerHoldSeconds must be positive";
      }
      {
        assertion =
          !cfg.enableDirectModeInputShortcuts || (directDrmBrowserEnabled || directDrmStreamEnabled);
        message = "services.moonlight-client.enableDirectModeInputShortcuts requires a configured direct-display stream";
      }
      {
        assertion = cfg.browserScaleFactor > 0.0;
        message = "services.moonlight-client.browserScaleFactor must be positive";
      }
      {
        assertion = lib.elem cfg.browserPresentationScale [
          1.0
          1.5
        ];
        message = "services.moonlight-client.browserPresentationScale must be 1.0 or 1.5";
      }
      {
        assertion = lib.all (layout: lib.elem layout (lib.splitString "," cfg.keyboardLayouts)) (
          lib.attrNames cfg.keyboardLayoutDeviceOverrides
        );
        message = ''
          services.moonlight-client.keyboardLayoutDeviceOverrides keys must
          name layouts configured in keyboardLayouts
        '';
      }
      {
        assertion = lib.all (output: output != cfg.mirrorOutputs.${output}) (
          lib.attrNames cfg.mirrorOutputs
        );
        message = "services.moonlight-client.mirrorOutputs cannot mirror an output to itself";
      }
      {
        assertion = lib.all (output: output != cfg.softwareMirrorOutputs.${output}) (
          lib.attrNames cfg.softwareMirrorOutputs
        );
        message = "services.moonlight-client.softwareMirrorOutputs cannot mirror an output to itself";
      }
      {
        assertion = !dynamicExternalLayoutEnabled || cfg.autoLoginUser != null;
        message = "services.moonlight-client automatic external-output layout requires autoLoginUser";
      }
      {
        assertion =
          lib.intersectLists cfg.autoLayoutPrimaryWorkspaces cfg.autoLayoutSecondaryWorkspaces == [];
        message = "services.moonlight-client automatic primary and secondary workspace sets must not overlap";
      }
      {
        assertion =
          lib.intersectLists cfg.autoLayoutPrimaryWorkspaces cfg.autoLayoutTertiaryWorkspaces
          == []
          && lib.intersectLists cfg.autoLayoutSecondaryWorkspaces cfg.autoLayoutTertiaryWorkspaces == [];
        message = "services.moonlight-client automatic tertiary workspace set must not overlap the primary or secondary sets";
      }
      {
        assertion =
          lib.elem 1 cfg.autoLayoutPrimaryWorkspaces && lib.elem 2 cfg.autoLayoutPrimaryWorkspaces;
        message = "services.moonlight-client automatic primary workspace set must contain stream workspace 1 and browser workspace 2";
      }
      {
        assertion =
          !cfg.autoMirrorExternalOutputs
          || lib.elem cfg.autoMirrorWorkspace cfg.autoLayoutSecondaryWorkspaces;
        message = "services.moonlight-client.autoMirrorWorkspace must belong to the secondary workspace set";
      }
      {
        assertion = !cfg.enableMirrorToggle || cfg.autoLayoutExternalOutputs;
        message = "services.moonlight-client.enableMirrorToggle requires autoLayoutExternalOutputs";
      }
      {
        assertion = !cfg.forceSoftwareMirror || cfg.enableMirrorToggle;
        message = "services.moonlight-client.forceSoftwareMirror requires enableMirrorToggle";
      }
      {
        assertion = !cfg.enableAdaptiveDisplayLayout || cfg.autoLayoutExternalOutputs;
        message = "services.moonlight-client.enableAdaptiveDisplayLayout requires autoLayoutExternalOutputs";
      }
      {
        assertion = !cfg.enableMirrorToggle || !cfg.autoMirrorExternalOutputs;
        message = "services.moonlight-client on-demand and automatic mirroring are mutually exclusive";
      }
    ];
  };
}
