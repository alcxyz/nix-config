# modules/home-manager/services/t3code/default.nix
#
# Runs t3code in headless server mode (t3 serve), listening on all interfaces.
# The NixOS firewall restricts the port to the Netbird (wt0) interface.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.t3code;
in
{
  options.services.t3code = {
    enable = mkEnableOption "t3code headless server";

    port = mkOption {
      type = types.port;
      default = 3773;
      description = "Port to listen on.";
    };

    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Interface to bind. Defaults to all interfaces; the NixOS firewall restricts access to Netbird (wt0).";
    };

    baseDir = mkOption {
      type = types.str;
      default = config.home.homeDirectory;
      description = "Base directory t3code uses as the project root.";
    };
  };

  config = mkIf cfg.enable {
    systemd.user.services.t3code = {
      Unit = {
        Description = "t3code headless server";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.t3code}/bin/t3 serve --host ${cfg.host} --port ${toString cfg.port} --base-dir ${cfg.baseDir}";
        Environment = "SHELL=${pkgs.bash}/bin/bash";
        Restart = "on-failure";
        RestartSec = "10s";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
