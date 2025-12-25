# nix-config/modules/nixos/suites/gaming/sunshine.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  sunshineWrapped = "/run/wrappers/bin/sunshine-kiosk";
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

    systemd.user.services.sunshine-kiosk = {
      description = "Sunshine (wlr capture from headless sway)";
      after = [ "gaming-wm.service" ];
      requires = [ "gaming-wm.service" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";

        Environment = [
          "XDG_RUNTIME_DIR=%t"
          "WAYLAND_DISPLAY=gaming-wm/wayland-1"
          "SWAYSOCK=%t/gaming-wm/sway-gaming.sock"
          "PULSE_SERVER=unix:%t/pulse/native"
          "PIPEWIRE_REMOTE=pipewire-0"
        ];

        # FORCE the config file Sunshine must read
        ExecStart = "${sunshineWrapped} %h/.config/sunshine/sunshine.conf";

        Restart = "on-failure";
        RestartSec = 2;

        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
