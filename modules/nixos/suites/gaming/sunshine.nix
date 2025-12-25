# nix-config/modules/nixos/suites/gaming/sunshine.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  sunshineWrapped = "/run/wrappers/bin/sunshine-kiosk";

  sunshineConf = pkgs.writeText "sunshine.conf" ''
    sunshine_name = xyz
    capture = wlr
    port = 47989
    min_log_level = debug
    system_tray = disabled
  '';

  startSunshine = pkgs.writeShellScript "start-sunshine-gaming" ''
    set -euo pipefail

    : "''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set by systemd}"
    export WAYLAND_DISPLAY="wayland-1"

    test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"

    exec ${sunshineWrapped} ${sunshineConf}
  '';
in
{
  config = lib.mkIf config.suites.gaming.enable {
    security.wrappers.sunshine-kiosk = {
      source = "${pkgs.sunshine}/bin/sunshine";
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+ep";
    };

    networking.firewall.allowedTCPPorts = [ 47984 47989 47990 ];
    networking.firewall.allowedUDPPorts = [ 47998 47999 48000 48010 ];

    # IMPORTANT: this is a *user* unit
    systemd.user.services.sunshine-kiosk = {
      description = "Sunshine (wlr capture from headless sway)";
      after = [ "gaming-wm.service" ];
      requires = [ "gaming-wm.service" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";

        # Must match gaming-wm’s runtime dir (%t == /run/user/$UID for user units)
        Environment = [ "XDG_RUNTIME_DIR=%t/gaming-wm" ];

        ExecStart = "${startSunshine}";

        Restart = "on-failure";
        RestartSec = 2;

        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
