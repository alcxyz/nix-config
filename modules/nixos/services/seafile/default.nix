# /modules/nixos/services/seafile/default.nix
{ config, lib, pkgs, ... }:

{
  # 1. Define the dedicated system user and group for Seafile
  users.users.seafile = {
    isSystemUser = true;
    group = "seafile";
    home = "/var/lib/seafile"; # Seafile's data directory will be its home
  };
  users.groups.seafile = {};

  # 2. Define tmpfiles rules for Seafile's persistent data directories
  systemd.tmpfiles.rules = [
    "d /var/lib/seafile 0755 seafile seafile -"
    # Seafile itself will create necessary subdirectories like ccnet, seafile-server, etc.
  ];

  # 3. Main Seafile service configuration using the native NixOS module
  services.seafile = {
    enable = true;

    # Link to the user and group defined above
    user = "seafile";
    group = "seafile";
    # This is where Seafile will store all its data (libraries, files, logs)
    dataDir = "/var/lib/seafile";

    # Database connection settings for the host's native PostgreSQL
    database = {
      type = "postgresql";
      host = "localhost"; # Connect to the PostgreSQL instance running on the same host
      port = 5432;        # Default PostgreSQL port
      name = "seafile_db"; # The database created in PostgreSQL config
      user = "seafile_user"; # The user created in PostgreSQL config
      passwordFile = config.sops.secrets.seafile_db_password.path; # Secure password via sops
    };

    # Initial admin account setup. These values are read from your sops secrets.
    adminEmail = config.sops.secrets.seafile_admin_email.text;
    initialAdminPassword = config.sops.secrets.seafile_admin_password.path;

    # The external URL for Seafile (used in shares, notifications, etc.)
    ccnetSettings.General.SERVICE_URL = "https://seafile.nux.local";

    # Configure Seafile's internal file server. This listens on localhost,
    # and Traefik will proxy to this.
    seafileSettings = {
      fileserver = {
        host = "127.0.0.1"; # Binds internally to localhost
        port = 8082;        # Default port for Seafile's internal file server
      };
    };

    # Additional configuration for Seahub (the Python web UI).
    # The SECRET_KEY is crucial for Django's security.
    seahubExtraConf = ''
      SECRET_KEY = "${config.sops.secrets.seafile_secret_key.text}"
      # Example: If you want to configure email sending for password resets, etc.
      # EMAIL_USE_TLS = True
      # EMAIL_HOST = 'your_smtp_server.com'
      # EMAIL_PORT = 587
      # EMAIL_HOST_USER = 'your_smtp_username'
      # EMAIL_HOST_PASSWORD = 'your_smtp_password'
      # DEFAULT_FROM_EMAIL = 'no-reply@seafile.nux.local'
      # SERVER_EMAIL = 'no-reply@seafile.nux.local'
    '';

    # 4. Enable the native Memcached service, which Seafile uses for caching.
    services.memcached.enable = true;
    # Memcached will listen on localhost:11211 by default, which Seafile will use.

    # 5. Set systemd service timeouts for initial startup.
    # Seafile's first start involves database schema creation and can take time.
    systemd.services.seafile.serviceConfig = {
      TimeoutStartSec = "600s"; # Give it up to 10 minutes to start
    };

    # 6. Ensure Seafile waits for PostgreSQL and sops secrets to be ready.
    systemd.services.seafile.after = [ "postgresql.service" "sops-secrets.service" ];
    systemd.services.seafile.requires = [ "postgresql.service" ];
    systemd.services.seafile.wants = [ "sops-secrets.service" ];
    systemd.services.seafile.unitConfig = {
      ConditionPathExists = config.sops.secrets.seafile_db_password.path;
      ConditionPathExists = config.sops.secrets.seafile_admin_email.path;
      ConditionPathExists = config.sops.secrets.seafile_admin_password.path;
      ConditionPathExists = config.sops.secrets.seafile_secret_key.path;
      ConditionPathExists = "/run/postgresql/.s.PGSQL.5432"; # Check if PG socket exists
    };
  };

  # 7. Open the port that Seahub (Seafile's web UI) listens on for Traefik to connect.
  # Seahub (Django) typically listens on port 8000.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
