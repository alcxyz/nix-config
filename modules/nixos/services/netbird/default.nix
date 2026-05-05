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
  setupKeyFile =
    if cfg.setupKeyFile != null
    then cfg.setupKeyFile
    else config.sops.secrets.netbird_setup_key.path;
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

    services.netbird.clients.default.login.enable = false;

    systemd.services.netbird-managed-login = {
      description = "NetBird setup-key login";
      after = ["netbird.service"];
      requires = ["netbird.service"];
      wantedBy = ["multi-user.target"];
      restartTriggers = [setupKeyFile];
      path = [config.services.netbird.package pkgs.coreutils pkgs.gnugrep];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        status="$(netbird status 2>&1 || true)"

        if printf '%s\n' "$status" | grep -q ': Connected'; then
          exit 0
        fi

        if printf '%s\n' "$status" | grep -qi 'expired'; then
          netbird deregister || true
        fi

        netbird up --setup-key-file ${setupKeyFile}
      '';
    };

    system.activationScripts.netbird-login = lib.stringAfter ["setupSecrets"] ''
      if [ -e /run/systemd/system ]; then
        ${pkgs.systemd}/bin/systemctl daemon-reload || true
        ${pkgs.systemd}/bin/systemctl start netbird-managed-login.service || true
      fi
    '';
  };
}
