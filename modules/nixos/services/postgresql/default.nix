# /modules/nixos/services/postgresql/default.nix
{ config, lib, pkgs, ... }:

{
  services.postgresql = {
    enable = true;

    # Explicitly define the PostgreSQL package version.
    # For nixpkgs-25.05, this typically points to PostgreSQL 16.
    package = pkgs.postgresql;

    # Set the data directory for PostgreSQL.
    # NixOS will create this with correct permissions.
    dataDir = "/var/lib/postgresql/data";

    # This script runs once on the very first activation (when dataDir is empty)
    # to create initial databases and users.
    initialScript = ''
      -- Create the database for Seafile
      CREATE DATABASE seafile_db;
      
      -- Create the user for Seafile and set their password from the sops secret
      CREATE USER seafile_user WITH PASSWORD '${config.sops.secrets.seafile_db_password.text}';
      
      -- Grant all necessary privileges on the Seafile database to its user
      GRANT ALL PRIVILEGES ON DATABASE seafile_db TO seafile_user;

      -- IMPORTANT: If you decide to migrate LLDAP to PostgreSQL later,
      -- you would add its CREATE DATABASE and CREATE USER statements here.
    '';

    # These options ensure that the specified databases and users exist
    # on every 'nixos-rebuild switch'. They complement initialScript.
    ensureDatabases = [
      "seafile_db"
      # If you add more PostgreSQL databases for other services later, list them here.
    ];
    ensureUsers = [{
      name = "seafile_user";
      # This allows Seafile (or other applications) to manage their own schema/migrations within their database.
      #ensureDBOwnership = true;
    }];

    # PostgreSQL server settings.
    settings = {
      # Listen on localhost (127.0.0.1) by default.
      # This is secure as it only accepts connections from the same host.
      # Other services (like Seafile, Paperless) running natively on Nux, or Docker containers
      # routing through the host's network stack, can connect to this.
      listen_addresses = lib.mkDefault "127.0.0.1";

      # Enable logging for connections and disconnections. Useful for auditing.
      log_connections = true;
      log_disconnections = true;

      # Configure 'pg_hba.conf' to control client authentication.
      # This is crucial for security and connectivity.
      "pg_hba.conf" = ''
        # TYPE  DATABASE        USER            ADDRESS                 METHOD
        
        # Local connections (Unix socket) from the 'postgres' user or any local user
        local   all             all                                     trust
        
        # IPv4 connections from localhost (127.0.0.1)
        host    all             all             127.0.0.1/32            md5
        
        # IPv4 connections from the Docker bridge network.
        # This is important if you ever have Dockerized services (like a future LLDAP Docker image)
        # that need to connect to this native PostgreSQL instance.
        # Ensure '172.17.0.0/16' matches your actual Docker bridge subnet.
        host    all             all             172.17.0.0/16           md5
        
        # If you were to expose PostgreSQL to your entire LAN, you would add a line like:
        # host    all             all             192.168.1.0/24          md5
      '';
    };

    # The PostgreSQL service runs under its own system user and group,
    # which NixOS creates automatically. This is for reference.
    #user = "postgres";
    #group = "postgres";
  };

  # Define systemd-tmpfiles rules to ensure the PostgreSQL data directory exists
  # with the correct ownership and permissions.
  systemd.tmpfiles.rules = [
    "d /var/lib/postgresql 0755 postgres postgres -"
    "d /var/lib/postgresql/data 0700 postgres postgres -" # Data directory should be private
  ];

  # Do NOT open port 5432 in the main firewall unless you explicitly need
  # PostgreSQL to be accessible from other hosts on your LAN.
  # For local services and Docker containers, localhost access is sufficient.
  # If you do expose it, remember to change `listen_addresses` above to "0.0.0.0".
  # networking.firewall.allowedTCPPorts = [ 5432 ];
}
