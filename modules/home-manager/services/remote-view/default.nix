{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.remoteView;
  # Only the user can open this directory, so only their processes (and an
  # SSH session forwarding to the socket) reach the server; wayvnc's own
  # authentication is off (ADR-0102).
  stateDir = "${config.xdg.stateHome}/wayvnc";
  socket = "${stateDir}/vnc.sock";

  prepare = pkgs.writeShellScript "remote-view-prepare" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg stateDir}
    ${pkgs.coreutils}/bin/chmod 700 ${lib.escapeShellArg stateDir}
    # A socket left by an unclean exit would stop wayvnc from binding; the
    # RSA-AES key is no longer used.
    ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg socket} ${lib.escapeShellArg "${stateDir}/rsa_key.pem"}
  '';

  wayvnc = lib.getExe config.services.wayvnc.package;

  # A display that sleeps deeply enough to disconnect removes its output, and
  # wayvnc refuses to start on a missing one. Prefer the configured output when
  # it is there and otherwise let wayvnc pick, so the view stays reachable.
  start = pkgs.writeShellScript "remote-view-start" (
    lib.optionalString (cfg.output != null) ''
      if ${lib.getExe pkgs.wlr-randr} --json \
        | ${lib.getExe pkgs.jq} -e --arg output ${lib.escapeShellArg cfg.output} \
          'any(.[]; .name == $output and .enabled)' >/dev/null; then
        exec ${wayvnc} --unix-socket --output=${lib.escapeShellArg cfg.output}
      fi
    ''
    + ''
      exec ${wayvnc} --unix-socket
    ''
  );

  # The remote desk: a virtual output sized for the viewer that takes every
  # workspace while the physical outputs are off. wayvnc resizes outputs named
  # `HEADLESS-*` to the viewer's window on request (and moves them to 0,0,
  # which nothing else occupies while the physical outputs are off). `off` reloads the
  # compositor config, which re-enables the physical outputs with their own
  # rules; Hyprland then returns each workspace to its monitor.
  desk = "HEADLESS-REMOTE";
  remoteDesk = pkgs.writeShellApplication {
    name = "remote-desk";
    runtimeInputs = [pkgs.hyprland pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.wlr-randr pkgs.systemd config.services.wayvnc.package];
    text = ''
      desk=${lib.escapeShellArg desk}
      mode=${lib.escapeShellArg cfg.deskMode}
      home_output=${lib.escapeShellArg (lib.optionalString (cfg.output != null) cfg.output)}
      # Disabled even when disconnected, so a display that wakes and
      # reconnects while the desk is on stays dark.
      known_outputs=${lib.escapeShellArg (lib.concatStringsSep " " (lib.unique (cfg.physicalOutputs ++ lib.optional (cfg.output != null) cfg.output)))}

      usage() {
        echo "usage: remote-desk on|off|status|socket" >&2
        exit 2
      }

      die() {
        echo "remote-desk: $*" >&2
        exit 1
      }

      # Where the VNC server listens, for clients that tunnel to it; needs no
      # compositor.
      if [ "''${1:-}" = socket ]; then
        echo ${lib.escapeShellArg socket}
        exit 0
      fi

      # SSH sessions do not inherit the compositor's environment.
      if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || [ -z "''${WAYLAND_DISPLAY:-}" ]; then
        instance=$(hyprctl instances -j | jq -c 'max_by(.time) // empty')
        [ -n "$instance" ] || die "no running Hyprland instance"
        HYPRLAND_INSTANCE_SIGNATURE=$(jq -r .instance <<<"$instance")
        WAYLAND_DISPLAY=$(jq -r .wl_socket <<<"$instance")
        export HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY
      fi

      hypr() {
        local out
        out=$(hyprctl "$@")
        [ "$out" = ok ] || die "hyprctl $1 failed: $out"
      }

      has_desk() {
        hyprctl -j monitors all | jq -e --arg d "$desk" 'any(.[]; .name == $d)' >/dev/null
      }

      physical_enabled() {
        hyprctl -j monitors | jq -r --arg d "$desk" '.[] | select(.name != $d) | .name'
      }

      case "''${1:-}" in
        on)
          # Recreate the output so it takes the configured mode, but only while
          # a physical output is on: removing the last output makes wayvnc
          # exit and drop the viewer.
          if has_desk && [ -n "$(physical_enabled)" ]; then
            hypr output remove "$desk"
          fi
          hypr eval "hl.monitor({ output = \"$desk\", mode = \"$mode\", position = \"auto\", scale = 1 })"
          if has_desk; then
            # Kept because nothing else is on; a config reload may have reset
            # its mode, which output management changes in place.
            wlr-randr --output "$desk" --custom-mode "''${mode%@*}" \
              || echo "remote-desk: could not set $desk to $mode" >&2
          else
            hypr output create headless "$desk"
          fi
          # Disable the physical outputs in one request, before wayvnc moves to
          # the desk: a viewer resize commits the state of every output at
          # that moment.
          rules=""
          for name in $( (physical_enabled; tr ' ' '\n' <<<"$known_outputs") | sort -u); do
            case "$name" in
              *[!A-Za-z0-9_-]*) die "unexpected output name: $name" ;;
            esac
            rules+="hl.monitor({ output = \"$name\", disabled = true }) "
          done
          if [ -n "$rules" ]; then hypr eval "$rules"; fi
          # wayvnc may be restarting, which takes a few seconds.
          for _ in $(seq 40); do
            if wayvncctl output-set "$desk" >/dev/null 2>&1; then break; fi
            sleep 0.25
          done
          hypr dispatch "hl.dsp.focus({ monitor = \"$desk\" })"
          if ! wayvncctl output-list 2>/dev/null | grep -q "^\* $desk:"; then
            echo "remote-desk: wayvnc is not capturing $desk yet; it will once it runs" >&2
          fi
          ;;
        off)
          # Every resize wayvnc applies also marks the outputs that are off at
          # the time as disabled, and Hyprland keeps that mark over the config
          # for as long as wayvnc stays connected. Restarting wayvnc drops it
          # (and the viewer, which is done by now).
          systemctl --user try-restart wayvnc.service || true
          hypr reload
          for _ in $(seq 40); do
            if [ -n "$(physical_enabled)" ]; then break; fi
            sleep 0.25
          done
          if [ -z "$(physical_enabled)" ]; then
            # The rules are restored, but no display is connected; keep the
            # desk so wayvnc keeps running. A display that wakes takes its
            # workspaces back; run off again to remove the desk.
            echo "remote-desk: no physical output is connected; $desk stays until the next off" >&2
            exit 0
          fi
          if has_desk; then hypr output remove "$desk"; fi
          if [ -n "$home_output" ]; then
            wayvncctl output-set "$home_output" >/dev/null 2>&1 || true
          fi
          ;;
        status)
          hyprctl -j monitors all \
            | jq -r '.[] | "\(.name) \(.width)x\(.height) \(if .disabled then "off" else "on" end)"'
          ;;
        *) usage ;;
      esac
    '';
  };
in {
  # ADR-0102: view and drive the live Wayland desktop from another machine.
  # The server listens on a Unix socket in a directory only the user can
  # open and is reached through an SSH forward to it, so the SSH key is the
  # only credential; wayvnc's own authentication is off. A process of the
  # same user can connect, as it can already use the compositor's capture
  # and virtual-input protocols directly.
  options.services.remoteView = {
    enable = lib.mkEnableOption "a loopback-only wayvnc view of the live desktop";

    output = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "DP-1";
      description = ''
        Output captured at start when it is present; otherwise wayvnc picks
        one. wayvnc captures one output at a time, moves to another when its
        output disappears and does not move back; `wayvncctl output-set` or
        `output-cycle` switches while connected.
      '';
    };

    deskMode = lib.mkOption {
      type = lib.types.str;
      default = "1920x1080@60";
      example = "1728x1117@60";
      description = ''
        Mode the virtual output that `remote-desk on` creates starts in; a
        viewer that asks to resize the desktop (TigerVNC does by default)
        then sets it to its window. While it is on, the physical outputs are
        disabled.
      '';
    };

    physicalOutputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["DP-1" "HDMI-A-1"];
      description = ''
        Outputs `remote-desk on` disables even when they are disconnected at
        the time, so a display that reconnects stays dark. Connected outputs
        and `output` are always disabled.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [remoteDesk];

    services.wayvnc = {
      enable = true;
      autoStart = true;
      # With --unix-socket the address is the socket's path; the module
      # requires a port, which wayvnc then ignores.
      settings = {
        address = socket;
        port = 5900;
        enable_auth = false;
      };
    };

    systemd.user.services.wayvnc = {
      Service = {
        ExecStartPre = ["${prepare}"];
        ExecStart = lib.mkForce ["${start}"];
        # wayvnc exits cleanly when the compositor goes away; come back with
        # the next session instead of staying stopped.
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
