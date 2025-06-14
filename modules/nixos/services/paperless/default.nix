# /modules/nixos/services/paperless/default.nix
{ config, lib, pkgs, ... }:

{
  # Dependencies
  services.postgresql.enable = true;
  services.redis.servers."paperless" = {
    enable = true;
    port = 6379;
  };

  # Use the built-in Paperless service
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 8000;
    passwordFile = config.sops.secrets.paperless_password.path;
    settings = {
      PAPERLESS_URL = "https://paperless.nux.local";
      PAPERLESS_TIME_ZONE = config.time.timeZone;
      PAPERLESS_OCR_LANGUAGE = "eng+deu";
      PAPERLESS_TRUSTED_PROXIES = [ "127.0.0.1" ];
    };
  };

  # Add Paperless to Traefik
  services.traefik.dynamicConfigOptions.http = {
    routers.paperless = {
      rule = "Host(`paperless.nux.local`)";
      entryPoints = [ "websecure" ];
      service = "paperless";
      tls = true;
    };
    services.paperless = {
      loadBalancer.servers = [{ url = "http://localhost:8000"; }];
    };
  };
}
