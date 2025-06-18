# /modules/nixos/services/seafile/default.nix
{ config, lib, pkgs, ... }:

{
  # Add Seafile database to PostgreSQL (this will merge with Paperless config)
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "seafile" ];
    ensureUsers = [{
      name = "seafile";
      ensureDBOwnership = true;
    }];
  };

  # Memcached for Seafile
  services.memcached.enable = true;

  # Seafile with PostgreSQL
  services.seafile = {
    enable = true;
    dataDir = "/var/lib/seafile";
    
    # Admin setup
    adminEmail = "admin@yourdomain.com"; # Replace with your email
    initialAdminPassword = config.sops.secrets.seafile_admin_password.path;
    
    # External URL
    ccnetSettings.General.SERVICE_URL = "https://seafile.nux.local";
    
    # PostgreSQL configuration
    seafileSettings = {
      database = {
        type = "postgresql";
        host = "localhost";
        port = 5432;
        name = "seafile";
        user = "seafile";
      };
    };
    
    # Seahub configuration
    seahubExtraConf = ''
      with open('${config.sops.secrets.seafile_secret_key.path}', 'r') as f:
          SECRET_KEY = f.read().strip()
    '';
  };

  # Ensure PostgreSQL starts before Seafile
  systemd.services.seafile.after = [ "postgresql.service" ];

  # Open port for Traefik
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
