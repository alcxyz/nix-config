{ options
, config
, lib
, ...
}:
with lib;
with lib.custom; let
  cfg = config.hardware.networking.bridge;
in
{
  options.hardware.networking.bridge = with types; {
    enable = mkBoolOpt false "Enable pipewire";
  };

  config = mkIf cfg.enable {
    networking = {
      networkmanager.enable = true;
      hostId = "4e7ded69";
      bridges.br0.interfaces = [ "enp7s0" ];
      interfaces = {
        enp6s0 = {
          useDHCP = true; 
        };
        enp7s0 = {
          useDHCP = false;
          ipv4.addresses = []; # No static IPv4 addresses
          ipv6.addresses = []; # No static IPv6 addresses
          linkLocalAddressing = "disable";
        };
        br0 = {
          useDHCP = false;
          ipv4.addresses = []; # No static IPv4 addresses
          ipv6.addresses = []; # No static IPv6 addresses
          linkLocalAddressing = "disable";
        };
        #enp7s0 = {
        #  useDHCP = false; # Do not use DHCP for enp7s0
        #  # Ensure enp7s0 doesn't get an IP address; it's only used as part of the bridge
        #  ipv4.addresses = [ ];
        #  ipv6.addresses = [ ];
        #};
        # Configure br0 without IP addresses if it's exclusively for VM use
        #br0 = {
        #  useDHCP = false; # Do not use DHCP for enp7s0
        #  ipv4.addresses = [ ];
        #  ipv6.addresses = [ ];
        #};
      };
      #firewall = {
      #  enable = false;
      #  allowPing = true;
      #  allowedTCPPorts = [ ]; # Add any TCP ports you want to allow
      #  allowedUDPPorts = [ ]; # Add any UDP ports you want to allow
      #  interfaces.br0.allowedTCPPorts = [ ]; # Allow TCP traffic on br0
      #  interfaces.br0.allowedUDPPorts = [ ]; # Allow UDP traffic on br0
      #  trustedInterfaces = [ "br0" ];
      #};
    };
  };
}

