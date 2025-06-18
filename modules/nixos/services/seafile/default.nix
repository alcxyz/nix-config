# /modules/nixos/services/seafile/default.nix
{ config, lib, pkgs, ... }:

{
  # 1. Define the dedicated system user and group for the Seafile service.
  users.users.seafile = {
    isSystemUser = true;
    group = "seafile";
    home = "/var/lib/seafile"; # Seafile's data directory will be its home
  };
  users.groups.seafile = {};

  # 2. Define systemd-tmpfiles rules for Seafile's persistent data directories.
  systemd.tmpfiles.rules = [
    "d /var/lib/seafile 0755 seafile seafile -"
  ];

  # 3. Main Seafile service configuration using the native NixOS module.
  services.seafile = {
    enable = true;

    # User and group for the service to run as.
    user = "seafile";
    group = "seafile";
    dataDir = "/var/lib/seafile";

    # Database connection settings.
    seafileSettings = {
      fileserver = {
        host = "127.0.0.1";
        port = 8082;
      };
      database = {
        type = "postgresql";
        host = "localhost";
        port = 5432;
        name = "seafile_db";
        user = "seafile_user";
        password = config.sops.secrets.seafile_db_password.text; # Actual password text
      };
    };

    # Admin account setup.
    adminEmail = config.sops.secrets.seafile_admin_email.text;
    initialAdminPassword = config.sops.secrets.seafile_admin_password.path;

    # External URL for Seafile.
    ccnetSettings.General.SERVICE_URL = "https://seafile.nux.local";

    # Additional Seahub configuration.
    seahubExtraConf = ''
      SECRET_KEY = "${config.sops.secrets.seafile_secret_key.text}"
    '';
  };

  # === THE FIX ===
  # 4. Enable Memcached service at the TOP LEVEL of the module.
  # This makes services.memcached an independent service that Seafile will connect to.
  services.memcached.enable = true;

  # === THE FIX ===
  # 5. Define systemd service unit configuration for Seafile.
  # This block must be at the top level, under 'systemd.services'.
  systemd.services.seafile = {
    # Set systemd service timeouts for initial startup.
    serviceConfig = {
      TimeoutStartSec = "600s"; # 10 minutes
    };

    # Define systemd unit dependencies to ensure Seafile starts only after
    # PostgreSQL is running and sops secrets are decrypted and available.
    after = [ "postgresql.service" "sops-secrets.service" ];
    requires = [ "postgresql.service" ];
    wants = [ "sops-secrets.service" ];
    
    # Condition checks for secret files and PostgreSQL socket.
    unitConfig = {
      ConditionPathExists = [
        config.sops.secrets.seafile_db_password.path
        config.sops.secrets.seafile_admin_email.path
        config.sops.secrets.seafile_admin_password.path
        config.sops.secrets.seafile_secret_key.path
        "/run/postgresql/.s.PGSQL.5432" # Checks for the PostgreSQL Unix socket file.
      ];
    };
  };

  # 6. Open the port that Seahub (Seafile's web UI) listens on for Traefik to connect.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
