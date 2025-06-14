# /modules/nixos/services/lldap/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in LLDAP service
  services.lldap = {
    enable = true;
    settings = {
      http_url = "https://ldap.nux.local";
      jwt_secret_file = config.sops.secrets.lldap_jwt.path;
      ldap_user_pass_file = config.sops.secrets.lldap_admin_password.path;
    };
  };

  # Add LLDAP to Traefik
  services.traefik.dynamicConfigOptions.http = {
    routers.lldap = {
      rule = "Host(`ldap.nux.local`)";
      entryPoints = [ "websecure" ];
      service = "lldap";
      tls.certResolver = "letsencrypt";
    };
    services.lldap = {
      loadBalancer.servers = [{ url = "http://localhost:17170"; }];
    };
  };
}
