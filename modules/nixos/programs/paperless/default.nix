# /modules/nixos/programs/paperless/default.nix
{ config, pkgs, ... }:

let
  # --- Configuration ---
  # The IP address of your Traefik server.
  # This is needed so Paperless can trust the proxy headers.
  traefikIP = "192.168.1.3"; # <-- EDIT: Set the IP of your rpi0

  # The domain you configured in Traefik.
  paperlessDomain = "paperless.local";
in
{
  # --- Dependencies ---
  services.postgresql.enable = true;
  services.redis.enable = true;

  # --- Paperless-ngx Service ---
  services.paperless-ngx = {
    enable = true;

    # Tell Paperless its public-facing URL. This is important for generating correct links.
    url = "httpss://${paperlessDomain}";

    # Listen on all network interfaces on port 8000 so Traefik can reach it.
    listenAddress = "0.0.0.0";
    port = 8000;

    initialUser = {
      username = "admin";
      passwordFile = "/etc/nixos/secrets/paperless_password";
    };

    settings = {
      # <-- EDIT your timezone
      PAPERLESS_TIME_ZONE = "Europe/Berlin";
      # <-- EDIT your OCR languages
      PAPERLESS_OCR_LANGUAGE = "eng+deu";

      # CRITICAL: Trust headers from your Traefik proxy.
      # This allows Paperless to see the original client IP and protocol (https).
      PAPERLESS_TRUSTED_PROXIES = [ traefikIP ];
    };
  };

  # --- Firewall ---
  # Open port 8000 so Traefik can connect to the Paperless service.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}

