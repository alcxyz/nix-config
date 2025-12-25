# nix-config/modules/nixos/suites/gaming/wm-base.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  swayConfig = pkgs.writeText "sway-gaming-headless.conf" ''
    xwayland disable
    output HEADLESS-1 enable
    output HEADLESS-1 mode 1920x1080@60Hz

    # Force a background color to ensure the compositor renders frames
    # and the output is advertised to Wayland clients.
    exec "${pkgs.swaybg}/bin/swaybg -c '#000000'"
  '';

  startSway = pkgs.writeShellScript "start-sway-gaming" ''
    set -euo pipefail

    : "''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set by systemd}"

    export WLR_BACKENDS="headless"
    export WLR_HEADLESS_OUTPUTS="1"
    export WLR_RENDERER="pixman"
    export WLR_LOG_LEVEL="1"

    rm -f "$XDG_RUNTIME_DIR/sway-gaming.sock" || true

    exec ${pkgs.sway}/bin/sway \
      --debug \
      --unsupported-gpu \
      --config ${swayConfig}
  '';

  linkIpcSock = pkgs.writeShellScript "link-sway-gaming-ipc" ''
    set -euo pipefail

    : "''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set by systemd}"

    link="$XDG_RUNTIME_DIR/sway-gaming.sock"

    for _ in $(seq 1 200); do
      sock="$(ls -1t "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -n1 || true)"
      if [ -n "$sock" ] && [ -S "$sock" ]; then
        rm -f "$link" || true
        ln -s "$sock" "$link"
        exit 0
      fi
      sleep 0.05
    done

    exit 1
  '';
in
{
  config = lib.mkIf config.suites.gaming.enable {
    environment.systemPackages = with pkgs; [ sway ];

    systemd.user.services.gaming-wm = {
      description = "Gaming WM (Sway headless) - user service";
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";

        RuntimeDirectory = "gaming-wm";
        RuntimeDirectoryMode = "0700";
        Environment = [ "XDG_RUNTIME_DIR=%t/gaming-wm" ];

        ExecStart = "${startSway}";
        ExecStartPost = "${linkIpcSock}";

        Restart = "on-failure";
        RestartSec = 1;

        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
