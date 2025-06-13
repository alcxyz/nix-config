# /modules/nixos/services/lldap/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.lldap;
in
{
  options.services.lldap = {
    enable = mkEnableOption "LLDAP (Lightweight LDAP)";
    domain = mkOption {
      type = types.str;
      description = "Domain to host the LLDAP web UI on.";
      example = "ldap.nux.local";
    };
  };

  config = mkIf cfg.enable {
    # --- LLDAP Service ---
    services.lldap = {
      enable = true;
      settings = {
        web_listen_url = "httpss://${cfg.domain}";
        jwt_secret_file = toString config.sops.secrets.lldap_jwt.path;
        ldap_user_pass_file =
          toString config.sops.secrets.lldap_admin_password.path;
      };
    };

    # --- Traefik Integration  ---
    services.traefik.dynamicConfigOptions.http = {
      routers.lldap = {
        rule = "Host(`${cfg.domain}`)";
        entryPoints = [ "websecure" ];
        service = "lldap";
        tls.certResolver = "letsencrypt";
      };
      services.lldap = {
        loadBalancer.servers = [{ url = "http://localhost:17170"; }];
      };
    };
  };
}
