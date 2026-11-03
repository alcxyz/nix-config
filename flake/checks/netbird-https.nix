{
  inputs,
  pkgs,
  ...
}: let
  system = inputs.nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      ../../modules/nixos/services/netbird-https
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        services.netbird-https = {
          enable = true;
          domain = "service.invalid";
          address = "100.64.0.2";
          email = "test@example.invalid";
          upstreamPort = 3000;
          credentialsFile = "/run/fixture";
        };
      }
    ];
  };
  c = system.config;
  v = c.services.nginx.virtualHosts."service.invalid";
in
  assert inputs.nixpkgs.lib.all (a: a.assertion) c.assertions;
  assert c.networking.firewall.extraStopCommands == "";
  assert inputs.nixpkgs.lib.hasInfix "iptables-restore --wait --noflush" c.networking.firewall.extraCommands;
  assert inputs.nixpkgs.lib.hasInfix "-i lo -j RETURN" c.networking.firewall.extraCommands;
  assert inputs.nixpkgs.lib.hasInfix "-d 100.64.0.2 ! -i wt0" c.networking.firewall.extraCommands;
  assert builtins.length v.listen == 1;
  assert (builtins.head v.listen).addr == "100.64.0.2";
  assert (builtins.head v.listen).ssl;
  assert v.locations."/".proxyWebsockets;
  assert v.locations."/".proxyPass == "http://127.0.0.1:3000";
  assert c.networking.firewall.allowedTCPPorts == [];
  assert c.networking.firewall.interfaces.wt0.allowedTCPPorts == [443];
  assert c.security.acme.certs."service.invalid".environmentFile == "/run/fixture";
  assert c.security.acme.certs."service.invalid".group == c.services.nginx.group;
  assert c.systemd.services.nginx.serviceConfig.Restart == "on-failure";
  assert c.systemd.services.nginx.unitConfig.StartLimitIntervalSec == "0";
  assert builtins.isString c.systemd.units."nginx.service".text;
  assert builtins.elem "nginx.service" c.security.acme.certs."service.invalid".reloadServices;
    c.environment.etc."nginx/nginx.conf".source
