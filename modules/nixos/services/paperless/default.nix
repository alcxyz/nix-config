# /modules/nixos/services/paperless/default.nix
{ config, lib, pkgs, ... }:

{
  # Enable PostgreSQL with Paperless database
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "paperless" ];
    ensureUsers = [{
      name = "paperless";
      ensureDBOwnership = true;
    }];
  };

  # Redis for Paperless
  services.redis.servers."paperless" = {
    enable = true;
    port = 6379;
  };

  # Paperless with PostgreSQL
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 8001; # Different from Seafile's 8000
    passwordFile = config.sops.secrets.paperless_password.path;
    
    settings = {
      PAPERLESS_URL = "https://paperless.nux.local";
      PAPERLESS_TIME_ZONE = config.time.timeZone;
      PAPERLESS_OCR_LANGUAGE = "eng+nor";
      PAPERLESS_TRUSTED_PROXIES = [ "127.0.0.1" ];
      
      # PostgreSQL configuration
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";
      PAPERLESS_DBHOST = "localhost";
      PAPERLESS_DBPORT = "5432";
    };
  };

  # Ensure PostgreSQL starts before Paperless
  systemd.services.paperless-scheduler.after = [ "postgresql.service" ];
  systemd.services.paperless-consumer.after = [ "postgresql.service" ];
  systemd.services.paperless-web.after = [ "postgresql.service" ];

  # Open port for Traefik
  networking.firewall.allowedTCPPorts = [ 8001 ];
}
