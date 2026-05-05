# modules/nixos/services/netbird/default.nix
#
# Thin wrapper around the upstream NixOS services.netbird module.
# Keeps host configs clean: just `services.netbird.managed.enable = true;`
{
  config,
  lib,
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

    services.netbird.clients.default.login = mkIf (cfg.setupKeyFile != null) {
      enable = true;
      setupKeyFile = cfg.setupKeyFile;
    };
  };
}
