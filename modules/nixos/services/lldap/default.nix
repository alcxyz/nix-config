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
    # <-- ADD THESE OPTIONS
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
    # --- LLDAP Service ---
    services.lldap = {
      enable = true;
      settings = {
        web_listen_url = "httpss://${cfg.domain}";
        # <-- USE THE OPTIONS HERE
        jwt_secret_file = toString cfg.jwtSecretFile;
        ldap_user_pass_file = toString cfg.ldapUserPassFile;
      };
    };

    # Traefik integration remains the same...
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
