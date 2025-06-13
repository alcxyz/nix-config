# /modules/nixos/programs/paperless/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.paperless;
in
{
  options.services.paperless = {
    enable = mkEnableOption "Paperless-ngx document management system";
    domain = mkOption {
      type = types.str;
      description = "Domain to host the Paperless-ngx web UI on.";
      example = "paperless.nux.local";
    };
  };

  config = mkIf cfg.enable {
    # --- Dependencies ---
    services.postgresql.enable = true;
    services.redis.enable = true;

    # --- Paperless-ngx Service ---
    services.paperless-ngx = {
      enable = true;
      url = "httpss://${cfg.domain}";
      listenAddress = "127.0.0.1";
      port = 8000;
      initialUser.passwordFile = config.sops.secrets.paperless_password.path;
      settings = {
        PAPERLESS_TIME_ZONE = config.time.timeZone;
        PAPERLESS_OCR_LANGUAGE = "eng+deu";
        PAPERLESS_TRUSTED_PROXIES = [ "127.0.0.1" ];
      };
    };

    # --- Traefik Integration ---
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
