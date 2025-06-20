# /modules/nixos/services/lldap/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in LLDAP service
  services.lldap = {
    enable = true;
    settings = {
      # Required base configuration
      ldap_base_dn = "dc=nux,dc=local";
      ldap_user_dn = "admin";
      ldap_user_email = "admin@nux.local";
      
      # Database (SQLite by default)
      database_url = "sqlite:///var/lib/lldap/users.db?mode=rwc";
      
      # Web interface
      http_url = "https://ldap.nux.local";
      http_host = "127.0.0.1";
      http_port = 17170;
      
      # LDAP interface  
      ldap_host = "0.0.0.0";
      ldap_port = 3890;
      
      # Secret files
      jwt_secret_file = config.sops.secrets.lldap_jwt.path;
      ldap_user_pass_file = config.sops.secrets.lldap_admin_password.path;
    };
  };

  # Traefik Routes for LLDAP
  services.traefik.dynamicConfigOptions.http = {
    routers.lldap = {
      rule = "Host(`ldap.nux.local`)";
      entryPoints = [ "websecure" ];
      service = "lldap";
      tls = true;
    };
    services.lldap = {
      loadBalancer.servers = [{ url = "http://localhost:17170"; }];
    };
  };

}
