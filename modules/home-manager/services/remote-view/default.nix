{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.remoteView;
  stateDir = "${config.xdg.stateHome}/wayvnc";
  rsaKey = "${stateDir}/rsa_key.pem";

  # The RSA-AES key identifies this server to the viewer (trust on first use).
  # It is generated on the host and never leaves it.
  ensureKey = pkgs.writeShellScript "remote-view-ensure-key" ''
    set -eu
    umask 077
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg stateDir}
    if [ ! -s ${lib.escapeShellArg rsaKey} ]; then
      # ssh-keygen refuses to overwrite an existing (even empty) file without
      # a prompt, and systemd gives it no stdin.
      ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg rsaKey}
      ${pkgs.openssh}/bin/ssh-keygen -q -m pem -t rsa -b 3072 -N "" \
        -f ${lib.escapeShellArg rsaKey}
      ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg "${rsaKey}.pub"}
    fi
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
        exec ${wayvnc} --output=${lib.escapeShellArg cfg.output}
      fi
    ''
    + ''
      exec ${wayvnc}
    ''
  );
in {
  # ADR-0102: view and drive the live Wayland desktop from another machine.
  # The server listens on loopback only and is reached through SSH; every
  # session authenticates with the user's own password through PAM. Within
  # the same-user limit this stops a local process from connecting by
  # accident, not a deliberate one, which can already use the compositor's
  # capture and virtual-input protocols directly.
  # The host must define the matching PAM service:
  # `security.pam.services.wayvnc = {};`.
  options.services.remoteView = {
    enable = lib.mkEnableOption "a loopback-only wayvnc view of the live desktop";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5900;
      description = "Loopback port wayvnc listens on.";
    };

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
  };

  config = lib.mkIf cfg.enable {
    services.wayvnc = {
      enable = true;
      autoStart = true;
      settings = {
        address = "127.0.0.1";
        inherit (cfg) port;
        enable_auth = true;
        enable_pam = true;
        rsa_private_key_file = rsaKey;
      };
    };

    systemd.user.services.wayvnc = {
      Service = {
        ExecStartPre = ["${ensureKey}"];
        ExecStart = lib.mkForce ["${start}"];
        # wayvnc exits cleanly when the compositor goes away; come back with
        # the next session instead of staying stopped.
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
