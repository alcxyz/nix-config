# /modules/nixos/services/paperless/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.paperless-traefik;
in
{
  options.services.paperless-traefik = {
    enable = mkEnableOption "Paperless-ngx with Traefik integration";
    domain = mkOption {
      type = types.str;
      description = "Domain to host the Paperless-ngx web UI on.";
      example = "paperless.nux.local";
    };
    passwordFile = mkOption {
      type = types.path;
      description = "Path to a file containing the initial admin user password.";
    };
  };

  config = mkIf cfg.enable {
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
      passwordFile = cfg.passwordFile;
      settings = {
        PAPERLESS_URL = "https://${cfg.domain}";
        PAPERLESS_TIME_ZONE = config.time.timeZone;
        PAPERLESS_OCR_LANGUAGE = "eng+deu";
        PAPERLESS_TRUSTED_PROXIES = [ "127.0.0.1" ];
      };
    };

    # Add Traefik integration
    services.traefik.dynamicConfigOptions.http = {
      routers.paperless = {
        rule = "Host(`${cfg.domain}`)";
        entryPoints = [ "websecure" ];
        service = "paperless";
        tls.certResolver = "letsencrypt";
      };
      services.paperless = {
        loadBalancer.servers = [{ url = "http://localhost:8000"; }];
      };
    };
  };
}
