{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.waynergy;
  macRawKeymap = builtins.readFile ./raw-keymap-mac-evdev.ini;
  sessionLauncher = pkgs.writeShellScript "waynergy-session-launcher" ''
    set -eu

    waynergy_pid=""

    stop_waynergy() {
      if [ -n "$waynergy_pid" ] && kill -0 "$waynergy_pid" 2>/dev/null; then
        kill "$waynergy_pid" 2>/dev/null || true
        wait "$waynergy_pid" 2>/dev/null || true
      fi
      waynergy_pid=""
    }

    trap stop_waynergy EXIT
    trap 'exit 0' HUP INT TERM

    manager_variable() {
      ${pkgs.systemd}/bin/systemctl --user show-environment \
        | ${pkgs.gnused}/bin/sed -n "s/^$1=//p" \
        | ${pkgs.coreutils}/bin/head -n 1
    }

    for _attempt in $(${pkgs.coreutils}/bin/seq 1 300); do
      runtime_dir="''${XDG_RUNTIME_DIR:-$(manager_variable XDG_RUNTIME_DIR)}"
      wayland_display="$(manager_variable WAYLAND_DISPLAY)"
      hyprland_signature="$(manager_variable HYPRLAND_INSTANCE_SIGNATURE)"

      if [ -n "$runtime_dir" ] \
        && [ -n "$wayland_display" ] \
        && [ -S "$runtime_dir/$wayland_display" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
        export WAYLAND_DISPLAY="$wayland_display"
        if [ -n "$hyprland_signature" ]; then
          export HYPRLAND_INSTANCE_SIGNATURE="$hyprland_signature"
        fi

        ${lib.optionalString cfg.requireLanAddress ''
      server_ip="$(${pkgs.getent}/bin/getent ahostsv4 ${lib.escapeShellArg cfg.serverAddress} \
        | ${pkgs.gawk}/bin/awk 'NR == 1 { print $1; exit }')"
      case "$server_ip" in
        10.*|192.168.*) ;;
        172.*)
          second_octet="$(printf '%s\n' "$server_ip" | ${pkgs.gawk}/bin/awk -F. '{ print $2 }')"
          if [ "$second_octet" -lt 16 ] || [ "$second_octet" -gt 31 ]; then
            echo "Refusing non-LAN Synergy endpoint" >&2
            exit 1
          fi
          ;;
        *)
          echo "Refusing non-LAN Synergy endpoint" >&2
          exit 1
          ;;
      esac

      route_device="$(${pkgs.iproute2}/bin/ip -4 route get "$server_ip" \
        | ${pkgs.gawk}/bin/awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
      case "$route_device" in
        ""|wg*|wt*|tun*|tap*|tailscale*)
          echo "Refusing Synergy route outside a physical LAN interface" >&2
          exit 1
          ;;
      esac
    ''}

        ${lib.optionalString cfg.useFocusedMonitorGeometry ''
      current_geometry=""
      while true; do
        geometry="$(${pkgs.hyprland}/bin/hyprctl -j monitors 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '
              ([.[] | select(.focused == true and .dpmsStatus == true)][0]
                // [.[] | select(.dpmsStatus == true)][0]
                // .[0]) as $monitor
              | if $monitor == null then empty
                else [($monitor.width / $monitor.scale | round),
                      ($monitor.height / $monitor.scale | round)]
                  | @tsv
                end
            ' || true)"

        if [ -n "$geometry" ] && { [ -z "$waynergy_pid" ] || [ "$geometry" != "$current_geometry" ]; }; then
          stop_waynergy
          screen_width="$(printf '%s\n' "$geometry" | ${pkgs.coreutils}/bin/cut -f 1)"
          screen_height="$(printf '%s\n' "$geometry" | ${pkgs.coreutils}/bin/cut -f 2)"
          ${cfg.package}/bin/waynergy \
            --width "$screen_width" \
            --height "$screen_height" &
          waynergy_pid=$!
          current_geometry="$geometry"
        elif [ -n "$waynergy_pid" ] && ! kill -0 "$waynergy_pid" 2>/dev/null; then
          wait "$waynergy_pid" 2>/dev/null || true
          waynergy_pid=""
          current_geometry=""
        fi

        ${pkgs.coreutils}/bin/sleep 0.5
      done
    ''}

        exec ${cfg.package}/bin/waynergy
      fi

      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "Wayland session environment did not become ready" >&2
    exit 1
  '';
in {
  options.services.waynergy = {
    enable = lib.mkEnableOption "Waynergy Synergy client for Wayland";

    package = lib.mkPackageOption pkgs "waynergy" {};

    serverAddress = lib.mkOption {
      type = lib.types.str;
      default = "mac";
      description = "Hostname or address of the Synergy server.";
    };

    screenName = lib.mkOption {
      type = lib.types.str;
      description = "Stable screen name presented to the Synergy server.";
    };

    sourceKeyboard = lib.mkOption {
      type = lib.types.enum [
        "standard"
        "mac"
      ];
      default = "standard";
      description = "Physical keycode layout used by the server computer.";
    };

    backend = lib.mkOption {
      type = lib.types.enum [
        "wlr"
        "kde"
        "uinput"
      ];
      default = "wlr";
      description = ''
        Input injection backend. The uinput backend makes Synergy input follow
        the same libinput path as physical devices, which is required by some
        XWayland applications.
      '';
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start Waynergy with the graphical session.";
    };

    useFocusedMonitorGeometry = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Advertise the focused, powered-on Hyprland monitor rather than the
        compositor's complete output bounding box. This avoids parked outputs
        distorting Synergy's absolute pointer coordinates.
      '';
    };

    requireLanAddress = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Refuse to start unless the server resolves to an RFC 1918 address over
        a non-overlay interface. Use this for latency-sensitive clients that
        must never fall back to a mesh VPN route.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    xdg.configFile = {
      "waynergy/config.ini".text = ''
        host = ${cfg.serverAddress}
        name = ${cfg.screenName}
        backend = ${cfg.backend}
        restart_on_fatal = true
        syn_raw_key_codes = true

        ${lib.optionalString (cfg.sourceKeyboard == "mac") ''
          [raw-keymap]
          ${macRawKeymap}
        ''}

        [idle-inhibit]
        enable = false

        [tls]
        enable = true
        tofu = true

        [log]
        level = 3
      '';
    };

    systemd.user.services.waynergy = lib.mkIf cfg.autoStart {
      Unit = {
        Description = "Waynergy Synergy client";
      };

      Service = {
        ExecStart = sessionLauncher;
        Environment = [
          "PATH=${
            lib.makeBinPath [
              cfg.package
              pkgs.wl-clipboard
              pkgs.coreutils
              pkgs.procps
            ]
          }"
        ];
        Restart = "always";
        RestartSec = 3;
      };

      # greetd/UWSM couch sessions do not necessarily activate Home Manager's
      # graphical-session.target. The launcher already waits for a valid
      # Wayland socket, so the persistent user target is the reliable owner.
      Install.WantedBy = ["default.target"];
    };
  };
}
