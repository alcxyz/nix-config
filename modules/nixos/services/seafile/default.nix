# /modules/nixos/services/seafile/default.nix
{ config, lib, pkgs, ... }:

{
  # Enable MySQL (MariaDB) for Seafile
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
  };

  # Memcached for Seafile
  services.memcached.enable = true;

  # Simple Seafile configuration - let it use defaults
  services.seafile = {
    enable = true;
    dataDir = "/var/lib/seafile";
    
    # Admin setup
    adminEmail = "post@alc.no";
    initialAdminPassword = config.sops.secrets.seafile_admin_password.path;
    
    # External URL
    ccnetSettings.General.SERVICE_URL = "https://seahub.nux.local";
    
    # Bind to TCP port
    seahubAddress = "[127.0.0.1]:8000";
    
    # Minimal Seahub configuration
    seahubExtraConf = ''
      with open('${config.sops.secrets.seafile_secret_key.path}', 'r') as f:
          SECRET_KEY = f.read().strip()
    '';
  };

  # Ensure MySQL starts before Seafile
  systemd.services.seaf-server.after = [ "mysql.service" ];
  systemd.services.seahub.after = [ "mysql.service" ];

  # Open port for Traefik
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
