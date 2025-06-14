# /modules/nixos/services/lldap/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.lldap-traefik;
in
{
  options.services.lldap-traefik = {
    enable = mkEnableOption "LLDAP with Traefik integration";
    domain = mkOption {
      type = types.str;
      description = "Domain to host the LLDAP web UI on.";
      example = "ldap.nux.local";
    };
    jwtSecretFile = mkOption {
      type = types.path;
      description = "Path to a file containing the JWT secret key.";
    };
    ldapUserPassFile = mkOption {
      type = types.path;
      description = "Path to a file containing the initial admin user password.";
    };
  };

  config = mkIf cfg.enable {
    # Use the built-in LLDAP service
    services.lldap = {
      enable = true;
      settings = {
        http_url = "https://${cfg.domain}";
        jwt_secret_file = toString cfg.jwtSecretFile;
        ldap_user_pass_file = toString cfg.ldapUserPassFile;
      };
    };

    # Add Traefik integration
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
