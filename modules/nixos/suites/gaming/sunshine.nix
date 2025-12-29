# nix-config/modules/nixos/suites/gaming/sunshine.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  sunshineWrapped = "/run/wrappers/bin/sunshine-kiosk";
  startSunshine = pkgs.writeShellScript "start-sunshine-kiosk" ''
    set -euo pipefail

    # Force Sunshine to read the HM-managed config (or your real file if you
    # later switch it to a non-HM-managed path).
    : "''${HOME:?HOME must be set}"
    : "''${XDG_CONFIG_HOME:=$HOME/.config}"

    # Make libcuda visible for NVENC on NixOS (driver libs live outside the store).
    export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    exec ${sunshineWrapped} "$XDG_CONFIG_HOME/sunshine/sunshine.conf"
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

    networking.firewall.allowedTCPPorts = [ 47984 47989 47990 48010 ];
    networking.firewall.allowedUDPPorts = [ 47998 47999 48000 48010 ];

    systemd.user.services.sunshine-kiosk = {
      description = "Sunshine (wlr capture from headless sway)";
      after = [ "gaming-wm.service" ];
      requires = [ "gaming-wm.service" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";

        UnsetEnvironment = [
          "DISPLAY"
          "XAUTHORITY"
        ];

        Environment = [
          "HOME=%h"
          "XDG_CONFIG_HOME=%h/.config"
          "LD_LIBRARY_PATH=/run/opengl-driver/lib"
          "XDG_RUNTIME_DIR=%t"
          "WAYLAND_DISPLAY=gaming-wm/wayland-1"
          "SWAYSOCK=%t/gaming-wm/sway-gaming.sock"
          "LIBVA_DRIVER_NAME=radeonsi"
          "VAAPI_DEVICE=/dev/dri/renderD128"
        ];

        WorkingDirectory = "%h/.config/sunshine";

        ExecStart =
          "${pkgs.sunshine}/bin/sunshine %h/.config/sunshine/sunshine.conf";

        Restart = "on-failure";
        RestartSec = 2;

        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
