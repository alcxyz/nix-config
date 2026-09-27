{
  self,
  lib,
  pkgs,
}: let
  hosts = lib.filterAttrs (_: host: host.config.services.k3s.enable) self.nixosConfigurations;
  valid = host: let
    c = host.config;
  in
    c.k3s.nodeIp
    != null
    && c.k3s.nodeInterface != null
    && c.services.k3s.package == host.pkgs.k3s-flannel-node-source
    && c.services.k3s.package.version == host.pkgs.k3s.version
    && builtins.elem "--node-ip=${c.k3s.nodeIp}" c.services.k3s.extraFlags
    && builtins.elem "--flannel-iface=${c.k3s.nodeInterface}" c.services.k3s.extraFlags;
in
  assert lib.all valid (builtins.attrValues hosts);
    pkgs.runCommand "flannel-source-contract" {} ''
      touch "$out"
    ''
