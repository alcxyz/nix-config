# modules/nixos/services/netbird/default.nix
#
# Thin wrapper around the upstream NixOS services.netbird module.
# Keeps host configs clean: just `services.netbird.managed.enable = true;`
{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
with lib; let
  cfg = config.services.netbird.managed;
in {
  options.services.netbird.managed = {
    enable = mkEnableOption "Netbird mesh VPN client";

    setupKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a NetBird setup key file used for non-interactive login.";
    };
  };

  config = mkIf cfg.enable {
    services.netbird.enable = true;

    # Allow the main user to control the netbird daemon
    users.users.${username}.extraGroups = ["netbird"];

    # Netbird needs to manage routes for peers
    services.netbird.useRoutingFeatures = "client";

    sops.secrets.netbird_setup_key = mkIf (cfg.setupKeyFile == null) {
      sopsFile = "${inputs.nix-secrets}/operators/secrets.yaml";
      key = "netbird_setup_key";
      owner = "root";
      group = "root";
    };

    services.netbird.clients.default.login = {
      enable = true;
      setupKeyFile =
        if cfg.setupKeyFile != null
        then cfg.setupKeyFile
        else config.sops.secrets.netbird_setup_key.path;
      systemdDependencies = ["sops-nix.service"];
    };

    systemd.services.netbird-login.restartTriggers = [
      config.sops.secrets.netbird_setup_key.path
    ];

    system.activationScripts.netbird-login = lib.stringAfter ["specialfs" "users" "groups"] ''
      if [ -e /run/systemd/system ]; then
        ${pkgs.systemd}/bin/systemctl start netbird-login.service || true
      fi
    '';
  };
}
