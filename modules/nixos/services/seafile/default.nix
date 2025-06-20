# /modules/nixos/services/seafile/default.nix
{ config, lib, pkgs, ... }:

{
  # 1. Seafile's Database
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
  };

  # 2. Seafile's Cache
  services.memcached.enable = true;

  # 3. The Seafile Service Itself
  services.seafile = {
    enable = true;
    dataDir = "/var/lib/seafile";

    adminEmail = "post@alc.no";
    # You can remove this line after the first successful setup
    initialAdminPassword = config.sops.secrets.seafile_admin_password.path;

    # This is the single, public-facing URL for your Seafile instance.
    # Clients will use this URL for both the web UI and file syncing.
    ccnetSettings.General.SERVICE_URL = "https://seafile.nux.local";

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

  # 4. Traefik Routes for Seafile
  services.traefik.dynamicConfigOptions.http = {
    # Router for the file sync server (/seafhttp)
    routers.seafile-http = {
      # This rule is more specific, so it gets higher priority
      priority = 11;
      rule = "Host(`seafile.nux.local`) && PathPrefix(`/seafhttp`)";
      entryPoints = [ "websecure" ];
      service = "seafile-http";
      middlewares = [ "seafile-stripprefix" ];
      tls = true;
    };

    # Router for the web UI (everything else)
    routers.seafile-web = {
      priority = 10;
      rule = "Host(`seafile.nux.local`)";
      entryPoints = [ "websecure" ];
      service = "seafile-web";
      tls = true;
    };

    # Service pointing to the file sync backend (port 8082)
    services.seafile-http.loadBalancer.servers = [{
      url = "http://127.0.0.1:8082";
    }];

    # Service pointing to the web UI backend (port 8000)
    services.seafile-web.loadBalancer.servers = [{
      url = "http://127.0.0.1:8000";
    }];

    # Middleware to strip the /seafhttp prefix before sending to the backend
    middlewares.seafile-stripprefix.stripPrefix.prefixes = [ "/seafhttp" ];
  };

  # 5. Systemd Dependencies and Firewall
  systemd.services.seaf-server.after = [ "mysql.service" ];
  systemd.services.seahub.after = [ "mysql.service" ];

  #networking.firewall.allowedTCPPorts = [ 8000 ];
  # We only need to open Traefik's ports, not Seafile's internal ones.
  # This is likely already done in your main traefik module.
}
