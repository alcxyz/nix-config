# /modules/nixos/services/paperless/default.nix
{ config, lib, pkgs, hostName, ... }:

{
  # Redis for Paperless (still needed for task queue and caching)
  services.redis.servers."paperless" = {
    enable = true;
    port = 6379;
  };

  # Paperless with SQLite (default)
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 8001;
    passwordFile = config.sops.secrets.paperless_password.path;
    
    settings = {
      PAPERLESS_URL = "https://paperless.${hostName}.local";
      PAPERLESS_TIME_ZONE = config.time.timeZone;
      PAPERLESS_OCR_LANGUAGE = "eng+nor";
      PAPERLESS_TRUSTED_PROXIES = [ "127.0.0.1" ];
      # No database settings = defaults to SQLite
    };
  };

  
  # Traefik routing is now in Docker traefik file provider
  # Routes defined in: /nuc/traefik/traefik-config/systemd-services.yml.tpl

  networking.firewall.allowedTCPPorts = [ 8001 ];

}
