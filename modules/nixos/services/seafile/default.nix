# /modules/nixos/services/seafile/default.nix
{ config, lib, pkgs, hostName, ... }:

{
  # Seafile's Database
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
  };

  # Seafile's Cache
  services.memcached.enable = true;

  # The Seafile Service Itself
  services.seafile = {
    enable = true;
    dataDir = "/var/lib/seafile";

    adminEmail = "post@alc.no";
    initialAdminPassword = config.sops.secrets.seafile_admin_password.path;

    # This is the single, public-facing URL for your Seafile instance.
    # Clients will use this URL for both the web UI and file syncing.
    ccnetSettings.General.SERVICE_URL = "https://seafile.${hostName}.local";

    # Bind Seahub (web UI) to localhost:8000
    seahubAddress = "[127.0.0.1]:8000";

    # The file server (seaf-server) will automatically bind to localhost:8082
    # We don't need to configure it here, just know the port.

    seahubExtraConf = ''
      # Read the secret key from the sops file at runtime
      with open('${config.sops.secrets.seafile_secret_key.path}', 'r') as f:
          SECRET_KEY = f.read().strip()
    '';
  };

  # Traefik routing is now in Docker traefik file provider
  # Routes defined in: /nuc/traefik/traefik-config/systemd-services.yml.tpl

  # Systemd Dependencies and Firewall
  systemd.services.seaf-server.after = [ "mysql.service" ];
  systemd.services.seahub.after = [ "mysql.service" ];

}
