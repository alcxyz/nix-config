# /modules/nixos/services/paperless/default.nix
{ config, lib, pkgs, ... }:

{
  # Dependencies
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
      PAPERLESS_OCR_LANGUAGE = "eng+nor";
      PAPERLESS_TRUSTED_PROXIES = [ "127.0.0.1" ];
    };
  };

}
