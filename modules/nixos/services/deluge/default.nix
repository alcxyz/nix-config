# modules/nixos/services/deluge/default.nix
{ config, lib, pkgs, ... }:

with lib; # Ensure lib is in scope for mkForce

# No top-level 'let cfg = ...;' here, as 'config.services.deluge' will be used directly
# or we define a local 'cfg' where needed if it simplifies long paths.

{
  # Define options for your custom Deluge service if this module is introducing them.
  # If this module is *only* overriding systemd settings for the *Nixpkgs* Deluge service,
  # then you wouldn't define options.services.deluge here, you'd just use
  # config.services.deluge which comes from Nixpkgs.
  #
  # Assuming this module is primarily for overriding the systemd unit of the
  # Nixpkgs Deluge service:

  config = mkIf config.services.deluge.enable { # Check if the Nixpkgs Deluge service is enabled

    systemd.services.deluged = {
      # You can add other top-level systemd unit options here if needed, like:
      # description = "My Custom Deluge Daemon";
      # after = [ "network.target" "my-zfs-mount.service" ];

      serviceConfig = {
        # Forcefully override ExecStartPre from the Nixpkgs module
        #ExecStartPre = lib.mkForce null;

        # Forcefully override ExecStart from the Nixpkgs module
        # Use config.services.deluge directly to access its options
        #ExecStart = lib.mkForce (
        #  "${pkgs.deluge}/bin/deluged --do-not-daemonize --config ${config.services.deluge.dataDir}"
        #);

        # Explicitly set other necessary serviceConfig options
        User = config.services.deluge.user;
        Group = config.services.deluge.group;
        WorkingDirectory = config.services.deluge.dataDir;
        # Type = "simple"; # Common for daemons not forking
        #Restart = "on-failure"; # Or "always"
        #RestartSec = "10s";
        # Path = [ pkgs.coreutils ... ]; # If deluged needs anything specific in PATH
      };
    };

    networking.firewall.allowedTCPPorts = [
      8112
      51413
    ];
    networking.firewall.allowedUDPPorts = [
      51413
    ];
    # This rule ensures the dataDir (defined by services.deluge.dataDir)
    # is created with the correct ownership and permissions.
    #systemd.tmpfiles.rules = [
    #  "d '${config.services.deluge.dataDir}' 0750 ${config.services.deluge.user} ${config.services.deluge.group} - -"
    #];
  };

  # Traefik Routes for Deluge
  services.traefik.dynamicConfigOptions.http = {
    routers.delugeweb = {
      rule = "Host(`deluge.xyz.local`)";
      entryPoints = [ "websecure" ];
      service = "deluge-web";
      tls = true;
    };
    services.delugeweb = {
      loadBalancer.servers = [{ url = "http://localhost:8112"; }];
    };
  };
}
